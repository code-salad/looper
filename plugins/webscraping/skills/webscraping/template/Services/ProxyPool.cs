using System.Net;

namespace Scraper.Services;

/// <summary>Supported proxy protocols.</summary>
public enum ProxyProtocol { Http, Socks5 }

/// <summary>Immutable proxy connection info.</summary>
public sealed record ProxyConfig(
    string Host,
    int Port,
    string? Username = null,
    string? Password = null,
    ProxyProtocol Protocol = ProxyProtocol.Http)
{
    /// <summary>Safe display string (no credentials).</summary>
    public override string ToString() =>
        $"{Protocol.ToString().ToLowerInvariant()}://{Host}:{Port}";
}

/// <summary>Configuration for proxy pool behavior.</summary>
public sealed class ProxyPoolOptions
{
    /// <summary>Max consecutive failures before blacklisting a proxy.</summary>
    public int MaxConsecutiveFailures { get; init; } = 10;

    /// <summary>Minimum interval between requests on the same proxy.</summary>
    public TimeSpan MinRequestInterval { get; init; } = TimeSpan.FromSeconds(8);

    /// <summary>
    /// Base blacklist duration. Each successive blacklisting doubles it
    /// (5 min -> 10 min -> 20 min -> 40 min -> 80 min -> capped).
    /// </summary>
    public TimeSpan BaseBlacklistDuration { get; init; } = TimeSpan.FromMinutes(5);

    /// <summary>Maximum blacklist duration cap.</summary>
    public TimeSpan MaxBlacklistDuration { get; init; } = TimeSpan.FromHours(2);

    /// <summary>Per-request timeout.</summary>
    public TimeSpan RequestTimeout { get; init; } = TimeSpan.FromSeconds(30);
}

/// <summary>
/// Runtime state for a single proxy: rate gate, failure tracking, blacklist with expiry.
/// Each proxy owns its own <see cref="HttpClient"/> configured with that proxy's address.
/// </summary>
public sealed class ProxyEntry
{
    public ProxyConfig Config { get; }
    public HttpClient Client { get; }

    // --- Counters ---
    public int ConsecutiveFailures { get; private set; }
    public int TotalSuccesses { get; private set; }
    public int TotalFailures { get; private set; }
    public DateTime LastUsedAt { get; private set; }

    // --- Blacklist with expiry ---
    public int BlacklistCount { get; private set; }
    public DateTime? BlacklistedUntil { get; private set; }

    public bool IsBlacklisted =>
        BlacklistedUntil.HasValue && DateTime.UtcNow < BlacklistedUntil.Value;

    public bool IsAvailable => !IsBlacklisted;

    // --- Per-proxy rate gate: 1 concurrent request, min interval between requests ---
    private readonly SemaphoreSlim _gate = new(1, 1);
    private DateTime _lastRequestTime;
    private readonly TimeSpan _minInterval;

    public ProxyEntry(ProxyConfig config, HttpClient client, TimeSpan minInterval)
    {
        Config = config;
        Client = client;
        _minInterval = minInterval;
    }

    /// <summary>
    /// Execute an action through this proxy, respecting the per-proxy rate limit.
    /// Only one request at a time; waits for the minimum interval between requests.
    /// </summary>
    public async Task<T> ExecuteAsync<T>(
        Func<HttpClient, Task<T>> action, CancellationToken ct = default)
    {
        await _gate.WaitAsync(ct);
        try
        {
            var elapsed = DateTime.UtcNow - _lastRequestTime;
            if (elapsed < _minInterval)
            {
                // Add jitter: 80%-120% of the remaining delay
                var remaining = _minInterval - elapsed;
                var jitter = remaining * (0.8 + Random.Shared.NextDouble() * 0.4);
                await Task.Delay(jitter, ct);
            }

            _lastRequestTime = DateTime.UtcNow;
            LastUsedAt = DateTime.UtcNow;
            return await action(Client);
        }
        finally
        {
            _gate.Release();
        }
    }

    /// <summary>Record a successful request. Resets consecutive failure counter.</summary>
    public void MarkSuccess()
    {
        ConsecutiveFailures = 0;
        TotalSuccesses++;
        // Gradually rehabilitate after sustained success
        if (BlacklistCount > 0 && TotalSuccesses % 20 == 0)
            BlacklistCount = Math.Max(0, BlacklistCount - 1);
    }

    /// <summary>
    /// Record a failed request. If consecutive failures reach the threshold,
    /// blacklists the proxy with exponentially increasing duration.
    /// </summary>
    public void MarkFailed(int maxFailures, TimeSpan baseDuration, TimeSpan maxDuration)
    {
        ConsecutiveFailures++;
        TotalFailures++;
        if (ConsecutiveFailures >= maxFailures)
        {
            BlacklistCount++;
            var multiplier = 1L << Math.Min(BlacklistCount - 1, 5);
            var ticks = Math.Min(baseDuration.Ticks * multiplier, maxDuration.Ticks);
            BlacklistedUntil = DateTime.UtcNow + TimeSpan.FromTicks(ticks);
            ConsecutiveFailures = 0;
            Console.Error.WriteLine(
                $"[proxy-pool] Blacklisted {Config} for " +
                $"{TimeSpan.FromTicks(ticks).TotalMinutes:F1}min (strike #{BlacklistCount})");
        }
    }
}

/// <summary>
/// Manages a pool of proxies with per-proxy rate limiting, LRU rotation,
/// and automatic blacklisting with exponential expiry.
///
/// <para>
/// Blacklist expiry: when a proxy accumulates too many consecutive failures
/// it is blacklisted for <c>BaseBlacklistDuration * 2^(strikeCount-1)</c>,
/// capped at <c>MaxBlacklistDuration</c>. After the expiry window passes
/// the proxy automatically becomes available again. Sustained success
/// gradually reduces the strike count.
/// </para>
/// </summary>
public sealed class ProxyPool : IAsyncDisposable
{
    private readonly List<ProxyEntry> _entries = [];
    private readonly ProxyPoolOptions _options;
    private readonly Lock _lock = new();

    public ProxyPool(ProxyPoolOptions? options = null)
    {
        _options = options ?? new();
    }

    /// <summary>Load proxies from a file.</summary>
    public static async Task<ProxyPool> LoadAsync(
        string path, ProxyPoolOptions? options = null)
    {
        if (!File.Exists(path))
            throw new FileNotFoundException($"Proxy file not found: {path}", path);

        var pool = new ProxyPool(options);
        var text = await File.ReadAllTextAsync(path);
        pool.LoadFromString(text);
        return pool;
    }

    /// <summary>
    /// Parse proxy definitions and create per-proxy HttpClients.
    /// <para>Supported formats:</para>
    /// <list type="bullet">
    ///   <item><c>host:port</c></item>
    ///   <item><c>host:port:user:pass</c></item>
    ///   <item><c>socks5://host:port</c></item>
    ///   <item><c>socks5://user:pass@host:port</c></item>
    ///   <item><c>http://user:pass@host:port</c></item>
    /// </list>
    /// Lines starting with <c>#</c> are comments.
    /// </summary>
    public void LoadFromString(string text)
    {
        // Dispose previous clients if reloading
        foreach (var entry in _entries) entry.Client.Dispose();
        _entries.Clear();

        var lines = text.Split('\n')
            .Select(l => l.Trim())
            .Where(l => l.Length > 0 && !l.StartsWith('#'));

        foreach (var line in lines)
        {
            var config = ParseProxy(line);
            if (config is null)
            {
                Console.Error.WriteLine($"[proxy-pool] Skipping malformed line: {line}");
                continue;
            }
            var client = CreateClient(config);
            _entries.Add(new ProxyEntry(config, client, _options.MinRequestInterval));
        }

        Console.Error.WriteLine($"[proxy-pool] Loaded {_entries.Count} proxies");
    }

    /// <summary>Select the least-recently-used available proxy.</summary>
    /// <exception cref="InvalidOperationException">No proxies loaded.</exception>
    /// <exception cref="AllProxiesBlacklistedException">All proxies are blacklisted.</exception>
    public ProxyEntry GetNext()
    {
        lock (_lock)
        {
            if (_entries.Count == 0)
                throw new InvalidOperationException(
                    "No proxies loaded. Call LoadAsync() or LoadFromString() first.");

            var best = _entries
                .Where(e => e.IsAvailable)
                .MinBy(e => e.LastUsedAt);

            if (best is null)
            {
                var soonest = _entries.MinBy(e => e.BlacklistedUntil)!;
                throw new AllProxiesBlacklistedException(
                    _entries.Count, soonest.BlacklistedUntil);
            }

            return best;
        }
    }

    /// <summary>
    /// High-level execution: pick a proxy via LRU, enforce the per-proxy rate limit,
    /// execute the action, and automatically track success or failure.
    /// <para>
    /// Only transient errors (5xx, 429, network/timeout) count as proxy failures.
    /// Client errors (4xx except 429) are rethrown without penalizing the proxy.
    /// </para>
    /// </summary>
    public async Task<T> ExecuteAsync<T>(
        Func<HttpClient, CancellationToken, Task<T>> action,
        CancellationToken ct = default)
    {
        var proxy = GetNext();
        try
        {
            var result = await proxy.ExecuteAsync(
                client => action(client, ct), ct);
            proxy.MarkSuccess();
            return result;
        }
        catch (Exception ex) when (IsProxyFault(ex))
        {
            proxy.MarkFailed(
                _options.MaxConsecutiveFailures,
                _options.BaseBlacklistDuration,
                _options.MaxBlacklistDuration);
            throw;
        }
        // Non-proxy errors (400, 404, validation, etc.) rethrow without marking
    }

    /// <summary>
    /// Wait until at least one proxy becomes available (blacklist expires),
    /// then return it. Useful for callers that want to block instead of fail.
    /// </summary>
    public async Task<ProxyEntry> WaitForAvailableAsync(CancellationToken ct = default)
    {
        while (true)
        {
            ct.ThrowIfCancellationRequested();
            try
            {
                return GetNext();
            }
            catch (AllProxiesBlacklistedException ex)
            {
                if (ex.EarliestAvailableAt is { } earliest)
                {
                    var wait = earliest - DateTime.UtcNow;
                    if (wait > TimeSpan.Zero)
                    {
                        Console.Error.WriteLine(
                            $"[proxy-pool] All blacklisted. Waiting {wait.TotalSeconds:F0}s...");
                        await Task.Delay(wait + TimeSpan.FromMilliseconds(100), ct);
                    }
                }
                else
                {
                    await Task.Delay(1000, ct);
                }
            }
        }
    }

    /// <summary>Is this error the proxy's fault (vs. application/target error)?</summary>
    private static bool IsProxyFault(Exception ex) => ex switch
    {
        HttpRequestException { StatusCode: HttpStatusCode.TooManyRequests } => true,
        HttpRequestException { StatusCode: >= HttpStatusCode.InternalServerError } => true,
        HttpRequestException { StatusCode: null } => true, // network-level failure
        TaskCanceledException => true, // timeout
        _ => false,
    };

    // --- Stats ---

    public int TotalCount => _entries.Count;

    public int AvailableCount
    {
        get { lock (_lock) return _entries.Count(e => e.IsAvailable); }
    }

    public ProxyPoolStats GetStats()
    {
        lock (_lock)
        {
            return new(
                Total: _entries.Count,
                Available: _entries.Count(e => e.IsAvailable),
                Blacklisted: _entries.Count(e => e.IsBlacklisted),
                TotalSuccesses: _entries.Sum(e => e.TotalSuccesses),
                TotalFailures: _entries.Sum(e => e.TotalFailures),
                NextUnblacklistAt: _entries
                    .Where(e => e.IsBlacklisted)
                    .MinBy(e => e.BlacklistedUntil)?.BlacklistedUntil
            );
        }
    }

    /// <summary>Get per-proxy details for monitoring dashboards.</summary>
    public IReadOnlyList<ProxyStatus> GetProxyStatuses()
    {
        lock (_lock)
        {
            return _entries.Select(e => new ProxyStatus(
                Proxy: e.Config.ToString(),
                Available: e.IsAvailable,
                Successes: e.TotalSuccesses,
                Failures: e.TotalFailures,
                BlacklistedUntil: e.BlacklistedUntil,
                BlacklistStrikes: e.BlacklistCount
            )).ToList();
        }
    }

    // --- Proxy parsing ---

    internal static ProxyConfig? ParseProxy(string line)
    {
        var protocol = ProxyProtocol.Http;

        if (line.StartsWith("socks5://", StringComparison.OrdinalIgnoreCase))
        {
            protocol = ProxyProtocol.Socks5;
            line = line[9..];
        }
        else if (line.StartsWith("http://", StringComparison.OrdinalIgnoreCase))
        {
            line = line[7..];
        }

        // user:pass@host:port format
        string? username = null, password = null;
        var atIdx = line.LastIndexOf('@');
        if (atIdx >= 0)
        {
            var auth = line[..atIdx].Split(':', 2);
            username = auth[0];
            password = auth.Length > 1 ? auth[1] : null;
            line = line[(atIdx + 1)..];
        }

        // host:port or host:port:user:pass
        var parts = line.Split(':');
        if (parts.Length < 2)
            return null;
        if (!int.TryParse(parts[1], out var port) || port is < 1 or > 65535)
            return null;

        // Legacy host:port:user:pass format
        if (username is null && parts.Length >= 4)
        {
            username = parts[2];
            password = parts[3];
        }

        return new ProxyConfig(parts[0], port, username, password, protocol);
    }

    private HttpClient CreateClient(ProxyConfig config)
    {
        var proxyUri = config.Protocol switch
        {
            ProxyProtocol.Socks5 => $"socks5://{config.Host}:{config.Port}",
            _ => $"http://{config.Host}:{config.Port}",
        };

        var webProxy = new WebProxy(proxyUri);
        if (config.Username is not null && config.Password is not null)
            webProxy.Credentials = new NetworkCredential(config.Username, config.Password);

        var handler = new SocketsHttpHandler
        {
            Proxy = webProxy,
            UseProxy = true,
            CookieContainer = new CookieContainer(),
            PooledConnectionLifetime = TimeSpan.FromMinutes(5),
            AutomaticDecompression = DecompressionMethods.All,
            ConnectTimeout = TimeSpan.FromSeconds(15),
        };

        return new HttpClient(handler) { Timeout = _options.RequestTimeout };
    }

    public async ValueTask DisposeAsync()
    {
        foreach (var entry in _entries)
            entry.Client.Dispose();
        _entries.Clear();
    }
}

// --- Supporting types ---

public sealed record ProxyPoolStats(
    int Total,
    int Available,
    int Blacklisted,
    int TotalSuccesses,
    int TotalFailures,
    DateTime? NextUnblacklistAt);

public sealed record ProxyStatus(
    string Proxy,
    bool Available,
    int Successes,
    int Failures,
    DateTime? BlacklistedUntil,
    int BlacklistStrikes);

public sealed class AllProxiesBlacklistedException(int total, DateTime? earliest)
    : Exception($"All {total} proxies blacklisted. Next available: {earliest:HH:mm:ss}")
{
    public int TotalProxies => total;
    public DateTime? EarliestAvailableAt => earliest;
}
