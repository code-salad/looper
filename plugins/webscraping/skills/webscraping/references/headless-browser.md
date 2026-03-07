# Headless Browser Scraping with Playwright (.NET)

Use browser automation only when lighter methods fail (Tier 4 — last resort).

## When You Need a Headless Browser

- Content rendered entirely by JavaScript (SPA with no SSR)
- Anti-bot requiring real browser fingerprint (TLS, canvas, WebGL)
- Interactions needed: clicks, scrolls, form submissions
- Cloudflare JS challenge pages
- Sites checking `navigator.webdriver` or similar bot signals

## Setup

```bash
dotnet add package Microsoft.Playwright --version 1.52.0
# Install browser binaries
dotnet tool install --global Microsoft.Playwright.CLI
playwright install chromium
```

## Basic Pattern — Single Page Scrape

```csharp
using Microsoft.Playwright;

using var playwright = await Playwright.CreateAsync();
await using var browser = await playwright.Chromium.LaunchAsync(new BrowserTypeLaunchOptions
{
    Headless = true,
    Args = new[] { "--disable-blink-features=AutomationControlled" },
});

var context = await browser.NewContextAsync(new BrowserNewContextOptions
{
    UserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
    ViewportSize = new ViewportSize { Width = 1920, Height = 1080 },
    Locale = "en-US",
    TimezoneId = "America/New_York",
});

var page = await context.NewPageAsync();

// Remove webdriver flag
await page.AddInitScriptAsync(@"
    Object.defineProperty(navigator, 'webdriver', { get: () => undefined });
    Object.defineProperty(navigator, 'plugins', { get: () => [1, 2, 3, 4, 5] });
");

await page.GotoAsync("https://example.com/products", new PageGotoOptions
{
    WaitUntil = WaitUntilState.NetworkIdle,
    Timeout = 30000,
});

// Wait for dynamic content
await page.WaitForSelectorAsync(".product-card", new PageWaitForSelectorOptions
{
    Timeout = 10000,
});

// Extract data
var products = await page.EvalOnSelectorAllAsync<List<Dictionary<string, string>>>(
    ".product-card",
    @"cards => cards.map(card => ({
        name: card.querySelector('.title')?.textContent?.trim() ?? '',
        price: card.querySelector('.price')?.textContent?.trim() ?? '',
        url: card.querySelector('a')?.href ?? '',
    }))"
);
```

## With Proxy Rotation

```csharp
// Launch browser with proxy
await using var browser = await playwright.Chromium.LaunchAsync(new BrowserTypeLaunchOptions
{
    Headless = true,
    Proxy = new Proxy
    {
        Server = "http://proxy-host:8080",
        Username = "user",
        Password = "pass",
    },
});

// Or SOCKS5
await using var browser2 = await playwright.Chromium.LaunchAsync(new BrowserTypeLaunchOptions
{
    Headless = true,
    Proxy = new Proxy { Server = "socks5://proxy-host:1080" },
});
```

### Rotating proxies per request

```csharp
// Read proxies from file
var proxies = File.ReadAllLines("proxies.txt")
    .Where(l => !string.IsNullOrWhiteSpace(l) && !l.StartsWith('#'))
    .ToArray();
var proxyIndex = 0;

async Task<T> WithRotatingProxy<T>(Func<IPage, Task<T>> action)
{
    var proxyUrl = proxies[Interlocked.Increment(ref proxyIndex) % proxies.Length];

    // Each request gets a fresh browser context with a different proxy
    var context = await browser.NewContextAsync(new BrowserNewContextOptions
    {
        Proxy = new Proxy { Server = proxyUrl },
        UserAgent = GetRandomUserAgent(),
    });

    try
    {
        var page = await context.NewPageAsync();
        return await action(page);
    }
    finally
    {
        await context.CloseAsync();
    }
}
```

## Infinite Scroll Pattern

```csharp
var allItems = new List<ProductData>();
var previousHeight = 0L;
var maxScrolls = 50;

for (var i = 0; i < maxScrolls; i++)
{
    // Scroll to bottom
    var currentHeight = await page.EvaluateAsync<long>("document.body.scrollHeight");
    if (currentHeight == previousHeight) break; // no new content loaded

    await page.EvaluateAsync("window.scrollTo(0, document.body.scrollHeight)");

    // Wait for new content to load
    await page.WaitForTimeoutAsync(2000); // or WaitForResponse for XHR
    previousHeight = currentHeight;

    // Extract newly loaded items
    var newItems = await page.EvalOnSelectorAllAsync<List<ProductData>>(
        ".product-card:not([data-scraped])",
        "cards => cards.map(c => ({ /* ... */ }))"
    );
    allItems.AddRange(newItems);

    // Mark as scraped to avoid re-extraction
    await page.EvaluateAsync(@"
        document.querySelectorAll('.product-card:not([data-scraped])')
            .forEach(c => c.setAttribute('data-scraped', 'true'));
    ");

    Console.Error.WriteLine($"[scroll] {i + 1}/{maxScrolls}, total items: {allItems.Count}");
}
```

## Intercepting API Calls (Best of Both Worlds)

Often the browser fetches data from an API internally. Intercept those calls to get structured JSON while the browser handles authentication/challenges.

```csharp
var apiResponses = new List<JsonDocument>();

// Listen for API responses
page.Response += async (_, response) =>
{
    if (response.Url.Contains("/api/products") && response.Status == 200)
    {
        var body = await response.BodyAsync();
        var json = JsonDocument.Parse(body);
        apiResponses.Add(json);
        Console.Error.WriteLine($"[intercept] Captured API response: {response.Url}");
    }
};

// Navigate — the browser makes the API calls, we capture the responses
await page.GotoAsync("https://example.com/products");
await page.WaitForLoadStateAsync(LoadState.NetworkIdle);

// Now apiResponses contains the structured JSON data
// No need to parse HTML at all
```

## Handling Login / Cookies

```csharp
// Login once, save cookies, reuse across sessions
var context = await browser.NewContextAsync();
var page = await context.NewPageAsync();

// Login
await page.GotoAsync("https://example.com/login");
await page.FillAsync("#email", "user@example.com");
await page.FillAsync("#password", "password123");
await page.ClickAsync("button[type=submit]");
await page.WaitForURLAsync("**/dashboard**");

// Save cookies for reuse
var cookies = await context.CookiesAsync();
var cookieJson = JsonSerializer.Serialize(cookies);
File.WriteAllText("cookies.json", cookieJson);

// Later: restore cookies
var savedCookies = JsonSerializer.Deserialize<List<Cookie>>(
    File.ReadAllText("cookies.json"));
await context.AddCookiesAsync(savedCookies);
```

## Performance Tips

| Tip | Impact |
|-----|--------|
| Block images/fonts/CSS | 2-5x faster page loads |
| Intercept XHR instead of parsing DOM | Structured data, no parsing |
| Reuse browser context | Avoid launch overhead per request |
| Set `WaitUntil = NetworkIdle` | Don't wait for unnecessary resources |
| Use `page.WaitForSelector` | More reliable than fixed delays |

### Block unnecessary resources

```csharp
await page.RouteAsync("**/*.{png,jpg,jpeg,gif,svg,woff,woff2,css}", async route =>
{
    await route.AbortAsync();
});

// Or block specific domains (analytics, ads)
await page.RouteAsync("**/*", async route =>
{
    var url = route.Request.Url;
    if (url.Contains("google-analytics") || url.Contains("facebook") || url.Contains("doubleclick"))
        await route.AbortAsync();
    else
        await route.ContinueAsync();
});
```

## Multi-Browser Orchestration

For large-scale browser scraping, run N browser instances in parallel pulling from a shared work queue. Each browser has its own Playwright instance and proxy.

```csharp
// N workers, each with own Playwright + Browser + proxy
var workers = Enumerable.Range(0, concurrentBrowsers).Select(id => Task.Run(async () =>
{
    var pw = await Playwright.CreateAsync();
    var proxyIdx = id % proxies.Count;
    var (browser, page) = await LaunchWithProxy(pw, proxies[proxyIdx]);
    await using var db = new ScraperDb(dbPath);
    var failures = 0;

    while (workQueue.TryDequeue(out var work))
    {
        cts.Token.ThrowIfCancellationRequested();
        try
        {
            await ScrapeItem(page, work, cts.Token);
            await db.CompleteWorkAsync(work.Key, cts.Token);
            failures = 0;
        }
        catch (OperationCanceledException) { throw; }
        catch
        {
            failures++;
            if (failures >= maxFailures)
            {
                // Kill browser, relaunch with different proxy
                proxyIdx = (proxyIdx + concurrentBrowsers) % proxies.Count;
                await browser.CloseAsync();
                (browser, page) = await LaunchWithProxy(pw, proxies[proxyIdx]);
                failures = 0;
            }
            workQueue.Enqueue(work); // re-queue for retry
        }
        await Task.Delay(delayMs, cts.Token);
    }

    await browser.CloseAsync();
    pw.Dispose();
})).ToArray();

await Task.WhenAll(workers);
```

### Key design points:

- **One Playwright instance per worker** — `Playwright.CreateAsync()` is not thread-safe across browsers. Each worker needs its own.
- **One DbContext per worker** — EF Core DbContext is not thread-safe. Each worker creates its own.
- **Proxy rotation = browser restart** — unlike HttpClient where you switch proxies per-request, Playwright proxies are set at launch. To rotate, close and relaunch.
- **Re-queue on failure** — failed items go back to the queue for another worker (possibly different proxy) to retry.
- **ConcurrentQueue** — thread-safe, lock-free. Workers call `TryDequeue` in a loop.

### Resource considerations

Each Chromium instance uses ~200-400 MB RAM. Plan accordingly:

| Browsers | Approx RAM | Recommended VPS |
|----------|-----------|-----------------|
| 5 | 1-2 GB | 4 GB RAM |
| 10 | 2-4 GB | 8 GB RAM |
| 20 | 4-8 GB | 16 GB RAM |

## WAF / Challenge Page Handling

Many sites show a challenge page before serving content. Detect and wait for resolution:

```csharp
async Task<bool> WaitForChallenge(IPage page, int timeoutMs = 30000)
{
    var title = await page.TitleAsync();
    var challengePatterns = new[] { "WAF", "Just a moment", "Checking your browser",
                                    "Access denied", "Please wait" };

    if (!challengePatterns.Any(p => title.Contains(p, StringComparison.OrdinalIgnoreCase)))
        return true; // no challenge

    try
    {
        // Build JS condition: title must not contain any challenge pattern
        var condition = string.Join(" && ",
            challengePatterns.Select(p => $"!document.title.includes('{p}')"));
        await page.WaitForFunctionAsync($"() => {condition}", null,
            new() { Timeout = timeoutMs });
        return true; // challenge resolved
    }
    catch (TimeoutException)
    {
        return false; // challenge NOT resolved — rotate proxy
    }
}

// Usage:
await page.GotoAsync(url, new() { WaitUntil = WaitUntilState.DOMContentLoaded });
if (!await WaitForChallenge(page))
{
    Console.Error.WriteLine($"[warn] Challenge not resolved for {url}");
    // Trigger proxy rotation or skip this item
}
```

## Extracting Embedded JSON via Browser

When using Playwright on SSR sites (Next.js, Nuxt), extract embedded JSON via `EvaluateAsync` instead of HTML parsing:

```csharp
// Next.js __NEXT_DATA__
var json = await page.EvaluateAsync<string?>("""
    (() => {
        const el = document.getElementById('__NEXT_DATA__');
        return el ? el.textContent : null;
    })()
""");

// Nuxt __NUXT_DATA__
var nuxtJson = await page.EvaluateAsync<string?>("""
    (() => {
        const el = document.getElementById('__NUXT_DATA__');
        return el ? el.textContent : null;
    })()
""");

// Generic: extract any window variable
var initialState = await page.EvaluateAsync<string?>("""
    (() => {
        const state = window.__INITIAL_STATE__ || window.__PRELOADED_STATE__;
        return state ? JSON.stringify(state) : null;
    })()
""");
```

This is preferred over AngleSharp when you're already running a browser, because:
1. The browser has already parsed and executed the page
2. No need for a second parsing step
3. Works even when anti-bot blocks direct HTTP requests

## When to Switch Back to Direct HTTP

After using the browser to solve an initial challenge, often you can:
1. Extract cookies/tokens from the browser session
2. Use those cookies with direct `HttpClient` requests (much faster)
3. Only re-launch the browser when cookies expire

```csharp
// Solve challenge with browser
await page.GotoAsync("https://example.com");
var cookies = await context.CookiesAsync();

// Transfer cookies to HttpClient
var handler = new HttpClientHandler();
foreach (var cookie in cookies)
{
    handler.CookieContainer.Add(new System.Net.Cookie(cookie.Name, cookie.Value, cookie.Path, cookie.Domain));
}
using var client = new HttpClient(handler);

// Now scrape directly — 10-100x faster
var response = await client.GetAsync("https://example.com/api/data");
```
