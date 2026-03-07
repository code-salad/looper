# Anti-Bot Detection & Bypass Strategies

## Detection Method 1: TLS Fingerprinting (JA3/JA4)

### What it detects
The server analyzes the TLS Client Hello packet to identify the client. Python's `requests`, Go's `net/http`, and .NET's `HttpClient` all have distinct TLS fingerprints that differ from real browsers.

### How to know you're being fingerprinted
- Getting 403s even with perfect headers
- Same request works in browser but fails in code
- Rotating User-Agent doesn't help
- Changing proxies doesn't help

### Bypass strategies

```csharp
// Option 1: Use browser automation (real browser TLS stack)
// This is the most reliable bypass — Playwright/Puppeteer use Chromium's TLS

// Option 2: Use curl-impersonate via Process
// curl-impersonate mimics browser TLS fingerprints
var process = new Process
{
    StartInfo = new ProcessStartInfo
    {
        FileName = "curl_chrome131", // curl-impersonate binary
        Arguments = $"-s -o - \"{url}\"",
        RedirectStandardOutput = true,
        UseShellExecute = false,
    }
};
process.Start();
var output = await process.StandardOutput.ReadToEndAsync();
await process.WaitForExitAsync();
```

## Detection Method 2: JavaScript Challenges (Cloudflare, Akamai, PerimeterX)

### Cloudflare

**Signals:** `cf-ray` header, `__cf_bm` cookie, challenge page with "Checking your browser..."

```csharp
// Strategy A: Solve challenge with browser, then use cookies in HttpClient
using var playwright = await Playwright.CreateAsync();
await using var browser = await playwright.Chromium.LaunchAsync(new BrowserTypeLaunchOptions
{
    Headless = true,
    Args = new[] { "--disable-blink-features=AutomationControlled" },
});

var context = await browser.NewContextAsync();
var page = await context.NewPageAsync();

// Navigate — Cloudflare challenge will auto-solve
await page.GotoAsync("https://target.com");
await page.WaitForLoadStateAsync(LoadState.NetworkIdle);

// Check if challenge was solved
var title = await page.TitleAsync();
if (title.Contains("Just a moment"))
{
    // Still on challenge page — wait longer
    await page.WaitForURLAsync(url => !url.Contains("challenge"), new PageWaitForURLOptions
    {
        Timeout = 30000,
    });
}

// Extract cookies for HttpClient use
var cookies = await context.CookiesAsync();
// Transfer to HttpClient handler (see headless-browser.md)
```

**Strategy B: FlareSolverr** (standalone service that solves Cloudflare challenges)

```csharp
// FlareSolverr runs as a Docker container
// docker run -p 8191:8191 flaresolverr/flaresolverr

var solverRequest = new
{
    cmd = "request.get",
    url = "https://target.com/api/data",
    maxTimeout = 60000,
};

using var client = new HttpClient();
var response = await client.PostAsJsonAsync("http://localhost:8191/v1", solverRequest);
var result = await response.Content.ReadFromJsonAsync<FlareSolverResult>();

// result.Solution.Cookies contains the bypass cookies
// result.Solution.Response contains the page HTML
```

### Akamai Bot Manager

**Signals:** `_abck` cookie, `sensor_data` POST to `/-/166/...`

- More aggressive than Cloudflare
- Generates a device fingerprint via JavaScript
- Checks mouse movements, keyboard events, touch events

**Bypass:** Browser automation is usually the only option. Direct HTTP bypass is unreliable because the sensor data generation is obfuscated and changes frequently.

### PerimeterX / HUMAN

**Signals:** `_px3` cookie, `/api/v2/collector` requests

- Similar to Akamai — JavaScript device fingerprinting
- Checks WebGL rendering, canvas fingerprint, audio fingerprint

**Bypass:** Browser automation with stealth plugins.

## Detection Method 3: Browser Fingerprinting

### What they check

| Signal | Bot Indicator | Fix |
|--------|--------------|-----|
| `navigator.webdriver` | `true` | Override to `undefined` |
| `navigator.plugins` | Empty array | Inject fake plugins |
| `navigator.languages` | Missing or `[""]` | Set via context options |
| Canvas fingerprint | Missing or uniform | Use real browser (Playwright) |
| WebGL renderer | `SwiftShader` | Use headed mode or GPU flags |
| `window.chrome` | Missing | Inject chrome object |
| `Notification.permission` | `denied` in automation | Override |
| Screen resolution | `0x0` or unusual | Set viewport in context |

### Stealth overrides for Playwright

```csharp
await page.AddInitScriptAsync(@"
    // Hide webdriver flag
    Object.defineProperty(navigator, 'webdriver', { get: () => undefined });

    // Fake plugins
    Object.defineProperty(navigator, 'plugins', {
        get: () => [1, 2, 3, 4, 5],
    });

    // Fake languages
    Object.defineProperty(navigator, 'languages', {
        get: () => ['en-US', 'en'],
    });

    // Add chrome object
    window.chrome = {
        runtime: {},
        loadTimes: function() {},
        csi: function() {},
        app: {},
    };

    // Override permissions
    const originalQuery = window.navigator.permissions.query;
    window.navigator.permissions.query = (parameters) =>
        parameters.name === 'notifications'
            ? Promise.resolve({ state: Notification.permission })
            : originalQuery(parameters);
");
```

## Detection Method 4: Behavioral Analysis

### What they track
- Request timing (too uniform = bot)
- Navigation patterns (jumping directly to deep pages)
- Mouse movements (none = bot)
- Session duration (too fast = bot)

### Bypass: Human-like behavior

```csharp
// Random delays between actions
async Task HumanDelay(int minMs = 500, int maxMs = 3000)
{
    await Task.Delay(Random.Shared.Next(minMs, maxMs));
}

// Simulate browsing pattern: homepage → category → product
await page.GotoAsync("https://example.com");
await HumanDelay(2000, 5000);

await page.ClickAsync("a[href='/products']");
await HumanDelay(1000, 3000);

await page.ClickAsync(".product-card:first-child a");
await HumanDelay();

// Random mouse movements
await page.Mouse.MoveAsync(
    Random.Shared.Next(100, 800),
    Random.Shared.Next(100, 600)
);
```

### Request timing jitter for direct HTTP

```csharp
// BAD: uniform timing (easily detected)
await Task.Delay(1000);

// GOOD: variable timing with natural distribution
async Task NaturalDelay(double meanMs = 2000, double stdDevMs = 800)
{
    // Box-Muller transform for normal distribution
    var u1 = Random.Shared.NextDouble();
    var u2 = Random.Shared.NextDouble();
    var normal = Math.Sqrt(-2.0 * Math.Log(u1)) * Math.Cos(2.0 * Math.PI * u2);
    var delay = Math.Max(200, meanMs + normal * stdDevMs);
    await Task.Delay((int)delay);
}
```

## Detection Method 5: Honeypot Traps

Hidden links or form fields designed to catch bots.

```csharp
// When parsing HTML, skip hidden elements
var visibleLinks = document.QuerySelectorAll("a[href]")
    .Where(a =>
    {
        var style = a.GetAttribute("style") ?? "";
        var classes = a.ClassName ?? "";

        // Skip elements with display:none, visibility:hidden, or zero dimensions
        if (style.Contains("display:none") || style.Contains("display: none")) return false;
        if (style.Contains("visibility:hidden") || style.Contains("visibility: hidden")) return false;
        if (style.Contains("opacity:0") || style.Contains("opacity: 0")) return false;
        if (classes.Contains("hidden") || classes.Contains("d-none")) return false;

        // Skip elements positioned off-screen
        if (style.Contains("position:absolute") && style.Contains("left:-")) return false;

        return true;
    })
    .Select(a => a.GetAttribute("href"))
    .Where(href => href != null)
    .ToList();
```

## Detection Method 6: Header Consistency Checks

The server checks if headers are consistent with a real browser.

### Common mistakes that trigger detection

| Mistake | Fix |
|---------|-----|
| Missing `sec-ch-ua` with Chrome UA | `Headers.Randomize()` handles this |
| `sec-fetch-site: cross-site` for same-site requests | Set `sec-fetch-site: same-origin` |
| `Referer` from a different domain | Set `Referer` to match target domain |
| Accept-Language mismatch with proxy geo | Match locale to proxy country |
| Missing Accept-Encoding | Always include `gzip, deflate, br` |
| Header order different from browsers | Chrome sends in specific order — match it |

### Correct header order for Chrome

```csharp
// Chrome sends headers in this specific order
request.Headers.TryAddWithoutValidation("sec-ch-ua", "\"Chromium\";v=\"131\", \"Not_A Brand\";v=\"24\"");
request.Headers.TryAddWithoutValidation("sec-ch-ua-mobile", "?0");
request.Headers.TryAddWithoutValidation("sec-ch-ua-platform", "\"Windows\"");
request.Headers.TryAddWithoutValidation("Upgrade-Insecure-Requests", "1");
request.Headers.TryAddWithoutValidation("User-Agent", "Mozilla/5.0 ...");
request.Headers.TryAddWithoutValidation("Accept", "text/html,application/xhtml+xml,...");
request.Headers.TryAddWithoutValidation("Sec-Fetch-Site", "none");
request.Headers.TryAddWithoutValidation("Sec-Fetch-Mode", "navigate");
request.Headers.TryAddWithoutValidation("Sec-Fetch-User", "?1");
request.Headers.TryAddWithoutValidation("Sec-Fetch-Dest", "document");
request.Headers.TryAddWithoutValidation("Accept-Encoding", "gzip, deflate, br, zstd");
request.Headers.TryAddWithoutValidation("Accept-Language", "en-US,en;q=0.9");
```

## Escalation Decision Tree

```
Request fails with 403/challenge?
├── Check: Is it TLS fingerprinting?
│   ├── Yes → Try curl-impersonate or browser automation
│   └── No ↓
├── Check: Is it header-based detection?
│   ├── Yes → Fix headers with Headers.Randomize(), match header order
│   └── No ↓
├── Check: Is it IP-based blocking?
│   ├── Yes → Switch to residential proxies, reduce rate
│   └── No ↓
├── Check: Is it JavaScript challenge?
│   ├── Cloudflare → FlareSolverr or browser + cookie extraction
│   ├── Akamai/PerimeterX → Browser automation only
│   └── No ↓
├── Check: Is it behavioral?
│   ├── Yes → Add jitter, simulate browsing patterns, use browser
│   └── No ↓
└── Investigate: Check the actual response body for clues
    └── Look for: CAPTCHA forms, blocked messages, redirect URLs
```
