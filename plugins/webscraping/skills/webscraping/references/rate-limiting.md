# Rate Limiting Scenarios & Solutions

## Scenario 1: Fixed Rate Limit (e.g., 60 req/min per IP)

The target returns `429 Too Many Requests` after exceeding a known threshold.

```csharp
// Configure proxy pool to stay under 1 req/sec per IP
var pool = await ProxyPool.LoadAsync("proxies.txt", new ProxyPoolOptions
{
    MinRequestInterval = TimeSpan.FromSeconds(1.2), // 50 req/min, safely under 60
});
```

### Detecting the limit

```csharp
// Log 429s to discover the actual threshold
int requestCount = 0;
var windowStart = DateTime.UtcNow;

var result = await pool.ExecuteAsync(async (client, ct) =>
{
    var resp = await client.SendAsync(request, ct);
    Interlocked.Increment(ref requestCount);

    if (resp.StatusCode == HttpStatusCode.TooManyRequests)
    {
        var elapsed = DateTime.UtcNow - windowStart;
        Console.Error.WriteLine(
            $"[rate-limit] Hit 429 after {requestCount} requests in {elapsed.TotalSeconds:F0}s");

        // Check Retry-After header
        if (resp.Headers.RetryAfter?.Delta is { } delta)
            Console.Error.WriteLine($"[rate-limit] Server says wait {delta.TotalSeconds}s");
    }
    return resp;
}, ct);
```

## Scenario 2: Sliding Window Rate Limit

The target tracks requests over a rolling window (e.g., 100 requests in any 60-second window).

```csharp
// Use a token bucket approach — track request timestamps per proxy
// The ProxyPool's MinRequestInterval handles this naturally:
// With 100 req/60s limit → interval = 60/100 = 0.6s per proxy
var pool = await ProxyPool.LoadAsync("proxies.txt", new ProxyPoolOptions
{
    MinRequestInterval = TimeSpan.FromMilliseconds(700), // 0.7s, safely under 0.6s
});
```

## Scenario 3: Adaptive Rate Limiting (Target Adjusts Dynamically)

Some APIs slow you down progressively before hard-blocking.

### Signals to watch for:
- Response times increasing (server is throttling)
- Partial data in responses (some fields omitted)
- Degraded results quality
- `X-RateLimit-Remaining` headers decreasing

```csharp
var interval = TimeSpan.FromSeconds(8);
int consecutiveSuccesses = 0;
int consecutive429s = 0;

async Task<HttpResponseMessage> FetchWithAdaptiveRate(string url, CancellationToken ct)
{
    return await pool.ExecuteAsync(async (client, innerCt) =>
    {
        var request = new HttpRequestMessage(HttpMethod.Get, url);
        Headers.Randomize(request);
        var response = await client.SendAsync(request, innerCt);

        if (response.StatusCode == HttpStatusCode.TooManyRequests)
        {
            consecutive429s++;
            consecutiveSuccesses = 0;

            // Exponential backoff on repeated 429s
            var backoff = Math.Min(consecutive429s * consecutive429s * 2, 120);
            Console.Error.WriteLine($"[adaptive] 429 #{consecutive429s}, backing off {backoff}s");
            await Task.Delay(TimeSpan.FromSeconds(backoff), innerCt);
        }
        else if (response.IsSuccessStatusCode)
        {
            consecutive429s = 0;
            consecutiveSuccesses++;

            // Speed up after sustained success
            if (consecutiveSuccesses >= 100 && interval > TimeSpan.FromSeconds(2))
            {
                interval = TimeSpan.FromTicks((long)(interval.Ticks * 0.8));
                consecutiveSuccesses = 0;
                Console.Error.WriteLine($"[adaptive] Reduced interval to {interval.TotalSeconds:F1}s");
            }
        }

        return response;
    }, ct);
}
```

## Scenario 4: Per-Endpoint Rate Limits

Different endpoints have different limits (e.g., search: 10/min, detail: 60/min).

```csharp
// Use separate proxy pools or separate interval tracking per endpoint
var searchPool = await ProxyPool.LoadAsync("proxies.txt", new ProxyPoolOptions
{
    MinRequestInterval = TimeSpan.FromSeconds(7), // ~8.5 req/min, under 10
});

var detailPool = await ProxyPool.LoadAsync("proxies.txt", new ProxyPoolOptions
{
    MinRequestInterval = TimeSpan.FromSeconds(1.2), // ~50 req/min, under 60
});

// Or use a single pool with manual delays between endpoint types
```

## Scenario 5: Rate Limit with API Keys / Tokens

When the rate limit is tied to an API key, not an IP.

```csharp
// Rotate API keys alongside proxies
var apiKeys = File.ReadAllLines("api-keys.txt")
    .Where(l => !string.IsNullOrWhiteSpace(l) && !l.StartsWith('#'))
    .ToArray();
var keyIndex = 0;

var result = await pool.ExecuteAsync(async (client, ct) =>
{
    var key = apiKeys[Interlocked.Increment(ref keyIndex) % apiKeys.Length];
    var request = new HttpRequestMessage(HttpMethod.Get,
        $"https://api.example.com/data?api_key={key}&page={page}");
    Headers.Randomize(request);
    return await client.SendAsync(request, ct);
}, ct);
```

## Scenario 6: Retry-After with Absolute Timestamps

Some servers return `Retry-After` as an HTTP date instead of seconds.

```csharp
// Polly handles both formats via the RetryAfter header parsing
DelayGenerator = args =>
{
    var retryAfter = args.Outcome.Result?.Headers.RetryAfter;
    if (retryAfter?.Delta is { } delta)
        return ValueTask.FromResult<TimeSpan?>(delta);
    if (retryAfter?.Date is { } date)
    {
        var wait = date - DateTimeOffset.UtcNow;
        return ValueTask.FromResult<TimeSpan?>(wait > TimeSpan.Zero ? wait : TimeSpan.FromSeconds(1));
    }
    return ValueTask.FromResult<TimeSpan?>(null);
},
```

## Key Principles

1. **Measure before tuning** — discover the actual limit with a small burst, don't guess
2. **Stay 10-20% under the limit** — jitter and clock skew can push you over
3. **Respect Retry-After** — ignoring it often leads to escalating blocks
4. **Per-IP vs per-account** — proxy rotation only helps with per-IP limits
5. **Monitor continuously** — rate limits can change without notice
