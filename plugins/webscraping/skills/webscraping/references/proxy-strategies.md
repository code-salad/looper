# Proxy Strategies & Patterns

## Strategy 1: Tiered Proxy Escalation

Start cheap, escalate only when blocked.

```
Attempt 1: No proxy (direct connection)
    ↓ blocked?
Attempt 2: Datacenter proxy ($1-5/GB)
    ↓ blocked?
Attempt 3: Residential proxy ($5-15/GB)
    ↓ blocked?
Attempt 4: Mobile proxy ($15-30/GB)
```

```csharp
// Implement tiered escalation
var tiers = new[]
{
    await ProxyPool.LoadAsync("proxies-datacenter.txt", new ProxyPoolOptions
    {
        MinRequestInterval = TimeSpan.FromSeconds(3),
    }),
    await ProxyPool.LoadAsync("proxies-residential.txt", new ProxyPoolOptions
    {
        MinRequestInterval = TimeSpan.FromSeconds(5),
    }),
};

async Task<HttpResponseMessage> FetchWithEscalation(string url, CancellationToken ct)
{
    foreach (var pool in tiers)
    {
        try
        {
            return await pool.ExecuteAsync(async (client, innerCt) =>
            {
                var request = new HttpRequestMessage(HttpMethod.Get, url);
                Headers.Randomize(request);
                var resp = await client.SendAsync(request, innerCt);
                if (resp.StatusCode == HttpStatusCode.Forbidden)
                    throw new HttpRequestException("Blocked, escalate");
                return resp;
            }, ct);
        }
        catch (HttpRequestException) { continue; }
        catch (AllProxiesBlacklistedException) { continue; }
    }
    throw new Exception("All proxy tiers exhausted");
}
```

## Strategy 2: Geo-Targeted Proxies

When the target serves different content or blocks based on geography.

```
# proxies-us.txt — US residential proxies
socks5://user:pass@us-proxy-1.example.com:1080
socks5://user:pass@us-proxy-2.example.com:1080

# proxies-eu.txt — EU residential proxies
socks5://user:pass@eu-proxy-1.example.com:1080
socks5://user:pass@eu-proxy-2.example.com:1080
```

```csharp
// Load geo-specific pools
var usPool = await ProxyPool.LoadAsync("proxies-us.txt", opts);
var euPool = await ProxyPool.LoadAsync("proxies-eu.txt", opts);

// Use the right pool for the right target
var pool = targetDomain.EndsWith(".de") || targetDomain.EndsWith(".fr")
    ? euPool
    : usPool;
```

## Strategy 3: Sticky Sessions (Same IP for a Workflow)

When you need the same IP across multiple requests (login → browse → scrape).

```csharp
// Get a specific proxy and reuse it for a session
var (proxyClient, proxyId) = pool.AcquireSpecific(); // hypothetical API

try
{
    // Login
    var loginReq = new HttpRequestMessage(HttpMethod.Post, "https://example.com/login");
    loginReq.Content = new FormUrlEncodedContent(new Dictionary<string, string>
    {
        ["email"] = "user@example.com",
        ["password"] = "pass",
    });
    Headers.Randomize(loginReq);
    var loginResp = await proxyClient.SendAsync(loginReq);

    // Scrape with same IP (cookies maintained by HttpClient's handler)
    for (var page = 1; page <= totalPages; page++)
    {
        var req = new HttpRequestMessage(HttpMethod.Get,
            $"https://example.com/api/data?page={page}");
        Headers.Randomize(req);
        var resp = await proxyClient.SendAsync(req);
        // process...
        await Task.Delay(2000); // polite delay on single IP
    }
}
finally
{
    pool.Release(proxyId);
}
```

## Strategy 4: Proxy Health Monitoring

Continuously monitor and remove dead proxies.

```csharp
// Periodic health check running in background
async Task MonitorProxyHealth(ProxyPool pool, CancellationToken ct)
{
    while (!ct.IsCancellationRequested)
    {
        var stats = pool.GetStats();
        Console.Error.WriteLine(
            $"[proxy-health] Available: {stats.Available}/{stats.Total}, " +
            $"Blacklisted: {stats.Blacklisted}, " +
            $"Success rate: {stats.SuccessRate:P0}");

        if (stats.Available == 0)
        {
            Console.Error.WriteLine(
                $"[proxy-health] WARNING: All proxies down! " +
                $"Next recovery at {stats.NextRecoveryTime:HH:mm:ss}");
        }

        await Task.Delay(TimeSpan.FromMinutes(1), ct);
    }
}

// Run in background
_ = Task.Run(() => MonitorProxyHealth(pool, cts.Token));
```

## Strategy 5: Proxy Pool Warm-Up

Test all proxies before starting a long scrape.

```csharp
async Task<int> WarmUpProxies(ProxyPool pool, string testUrl, CancellationToken ct)
{
    var working = 0;
    var failed = 0;

    // Test each proxy with a lightweight request
    var testTasks = Enumerable.Range(0, pool.TotalCount).Select(async _ =>
    {
        try
        {
            await pool.ExecuteAsync(async (client, innerCt) =>
            {
                var req = new HttpRequestMessage(HttpMethod.Head, testUrl);
                var resp = await client.SendAsync(req, innerCt);
                resp.EnsureSuccessStatusCode();
                return true;
            }, ct);
            Interlocked.Increment(ref working);
        }
        catch
        {
            Interlocked.Increment(ref failed);
        }
    });

    await Task.WhenAll(testTasks);
    Console.Error.WriteLine($"[warm-up] {working} working, {failed} failed out of {pool.TotalCount}");
    return working;
}

var workingCount = await WarmUpProxies(pool, "https://httpbin.org/ip", cts.Token);
if (workingCount < 3)
{
    Console.Error.WriteLine("[warm-up] Too few working proxies, aborting");
    return;
}
```

## Strategy 6: Rotating Proxy Services (Backconnect)

Some providers give you a single gateway URL that rotates IPs automatically.

```
# Backconnect proxy — each request gets a different IP
# No need for multiple proxy entries
gate.smartproxy.com:7777:user:pass
```

```csharp
// With a backconnect proxy, you only need ONE entry but may want
// multiple connections to parallelize
var pool = await ProxyPool.LoadAsync("proxies.txt", new ProxyPoolOptions
{
    // Lower interval since the provider handles rotation
    MinRequestInterval = TimeSpan.FromSeconds(1),
});

// The provider rotates IPs server-side, so each request
// through the same gateway gets a different exit IP
```

## Proxy File Format Reference

All supported formats in `proxies.txt`:

```
# === HTTP Proxies ===
host:port
host:port:username:password
http://host:port
http://username:password@host:port

# === SOCKS5 Proxies ===
socks5://host:port
socks5://username:password@host:port

# === With authentication ===
http://user:pass@192.168.1.1:8080
socks5://user:pass@10.0.0.1:1080

# Comments and blank lines are ignored
```

## Cost Optimization

| Strategy | Savings |
|----------|---------|
| Start with datacenter, escalate to residential only when blocked | 60-80% cost reduction |
| Cache responses in SQLite — never re-fetch completed work | Eliminates duplicate bandwidth |
| Block images/fonts when using browser automation | 50-70% bandwidth savings |
| Use compression (gzip/brotli) | 60-80% bandwidth savings |
| Run during off-peak hours (target's timezone) | Lower block rates, fewer retries |
| Use backconnect proxies for high-volume | Simpler management, often cheaper at scale |
