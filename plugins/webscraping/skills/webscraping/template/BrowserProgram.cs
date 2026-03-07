using System.Collections.Concurrent;
using System.Text.Json;
using Microsoft.EntityFrameworkCore;
using Microsoft.Playwright;
using Scraper.Data;

// ============================================================================
// BROWSER SCRAPER TEMPLATE — For targets requiring Playwright (Tier 4).
//
// Use this instead of Program.cs when the target has:
//   - WAF / Cloudflare challenge pages
//   - JS-rendered content (SPA or Next.js behind anti-bot)
//   - Anti-bot checking navigator.webdriver or TLS fingerprint
//
// Steps:
//   1. Define your work item type and DB entity below
//   2. Register the entity in ScraperDb (add DbSet + OnModelCreating)
//   3. Adjust concurrency and proxy settings
//   4. Update ScrapeWorkItem() with your target's URL and extraction logic
//   5. Run: dotnet run
//
// Key differences from the HTTP-based template:
//   - N long-lived browser instances instead of HttpClient pool
//   - Proxies configured at browser launch (not per-request)
//   - Proxy rotation = close browser + relaunch with new proxy
//   - WAF challenge detection + wait loop
//   - Failed work items re-queued for retry
// ============================================================================

// --- 1. Configuration ---

const int ConcurrentBrowsers = 10;
const int DelayBetweenRequestsMs = 500;
const int MaxConsecutiveFailures = 3;
const string DbPath = "data.db";
const string BaseUrl = "https://example.com";

// --- 2. Load proxies ---

var proxyList = new List<ProxyInfo>();
foreach (var line in await File.ReadAllLinesAsync("proxies.txt"))
{
    var trimmed = line.Trim();
    if (string.IsNullOrEmpty(trimmed) || trimmed.StartsWith('#')) continue;
    var parts = trimmed.Split(':');
    if (parts.Length == 4)
        proxyList.Add(new ProxyInfo(parts[0], int.Parse(parts[1]), parts[2], parts[3]));
    else if (parts.Length == 2)
        proxyList.Add(new ProxyInfo(parts[0], int.Parse(parts[1]), null, null));
    else
        Console.Error.WriteLine($"[proxy] Skipping malformed line: {trimmed}");
}
if (proxyList.Count == 0)
    throw new InvalidOperationException("No proxies loaded from proxies.txt");
Console.Error.WriteLine(
    $"[proxy] Loaded {proxyList.Count} proxies " +
    $"({proxyList.Count(p => p.User != null)} auth, " +
    $"{proxyList.Count(p => p.User == null)} no-auth)");

// --- 3. Database ---

{
    await using var initDb = new ScraperDb(DbPath);
    await initDb.Database.EnsureCreatedAsync();
    await initDb.Database.ExecuteSqlRawAsync("PRAGMA journal_mode = WAL;");
    await initDb.Database.ExecuteSqlRawAsync("PRAGMA synchronous = NORMAL;");
}

// --- 4. Graceful shutdown ---

using var cts = new CancellationTokenSource();
Console.CancelKeyPress += (_, e) =>
{
    e.Cancel = true;
    Console.Error.WriteLine("\n[shutdown] Ctrl+C received, finishing current requests...");
    cts.Cancel();
};

// --- 5. Build work queue ---
// Replace this with your own work item generation logic.
// Multi-dimensional example: iterate over (category, page) or (country, hsCode).

var workQueue = new ConcurrentQueue<WorkItem>();
var totalWork = 0;
{
    await using var queueDb = new ScraperDb(DbPath);

    // Example: load categories from a file, generate work items
    var categories = await File.ReadAllLinesAsync("categories.txt");
    foreach (var category in categories.Where(l => !string.IsNullOrWhiteSpace(l)))
    {
        var key = $"category:{category}";
        if (!await queueDb.IsCompletedAsync(key))
        {
            workQueue.Enqueue(new WorkItem(category, key));
            totalWork++;
        }
    }
}

var totalItems = totalWork; // adjust if you know total beforehand
Console.Error.WriteLine($"[resume] {totalItems - totalWork} already done, {totalWork} remaining");

if (totalWork == 0)
{
    Console.Error.WriteLine("[done] All work completed.");
    return;
}

// --- 6. Launch browser workers ---

var startTime = DateTime.UtcNow;
var processed = 0;
var totalResults = 0;

var workers = Enumerable.Range(0, ConcurrentBrowsers).Select(workerId => Task.Run(async () =>
{
    IBrowser? browser = null;
    IPlaywright? pw = null;
    await using var workerDb = new ScraperDb(DbPath);
    var proxyIndex = workerId % proxyList.Count;
    var consecutiveFailures = 0;

    // --- Browser launcher with proxy ---
    async Task<(IBrowser Browser, IPage Page)> LaunchBrowser(IPlaywright playwright, int pIndex)
    {
        var proxy = proxyList[pIndex];
        var launchOptions = new BrowserTypeLaunchOptions
        {
            Headless = true,
            // Update this path to match your Playwright install location
            // Find it: ls ~/.cache/ms-playwright/chromium-*/chrome-linux64/chrome
            // ExecutablePath = "/home/user/.cache/ms-playwright/chromium-1208/chrome-linux64/chrome",
            Args = ["--disable-blink-features=AutomationControlled", "--no-sandbox"],
            Proxy = new Proxy
            {
                Server = $"http://{proxy.Host}:{proxy.Port}",
                Username = proxy.User,
                Password = proxy.Pass,
            },
        };

        var b = await playwright.Chromium.LaunchAsync(launchOptions);
        var ctx = await b.NewContextAsync(new()
        {
            UserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " +
                        "(KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36",
            ViewportSize = new() { Width = 1920, Height = 1080 },
            Locale = "en-US",
        });

        // Anti-fingerprinting: hide webdriver flag
        await ctx.AddInitScriptAsync(
            "Object.defineProperty(navigator, 'webdriver', { get: () => false });");

        var p = await ctx.NewPageAsync();

        // Optional: block unnecessary resources for speed
        // await p.RouteAsync("**/*.{png,jpg,jpeg,gif,svg,woff,woff2,css}", r => r.AbortAsync());

        Console.Error.WriteLine(
            $"[worker-{workerId}] Browser launched via proxy " +
            $"{proxy.Host}:{proxy.Port}{(proxy.User != null ? " (auth)" : "")}");
        return (b, p);
    }

    try
    {
        pw = await Playwright.CreateAsync();
        (browser, var page) = await LaunchBrowser(pw, proxyIndex);

        while (workQueue.TryDequeue(out var work))
        {
            cts.Token.ThrowIfCancellationRequested();

            try
            {
                var results = await ScrapeWorkItem(page, work, cts.Token);

                if (results.Count > 0)
                {
                    await workerDb.AddBatchAsync(results, cts.Token);
                    Interlocked.Add(ref totalResults, results.Count);
                }

                await workerDb.CompleteWorkAsync(work.Key, cts.Token);
                consecutiveFailures = 0;
                var done = Interlocked.Increment(ref processed);

                // Progress reporting every 10 items
                if (done % 10 == 0)
                {
                    var elapsed = DateTime.UtcNow - startTime;
                    var rate = processed / elapsed.TotalMinutes;
                    var remaining = totalWork - processed;
                    var eta = rate > 0 ? TimeSpan.FromMinutes(remaining / rate) : TimeSpan.Zero;
                    Console.Error.WriteLine(
                        $"[progress] {done}/{totalWork} " +
                        $"({rate:F1}/min, ETA {eta:hh\\:mm}) " +
                        $"results: {totalResults}");
                }
            }
            catch (OperationCanceledException) { throw; }
            catch (Exception ex)
            {
                Console.Error.WriteLine($"[worker-{workerId}] {work.Key} failed: {ex.Message}");
                consecutiveFailures++;

                if (consecutiveFailures >= MaxConsecutiveFailures)
                {
                    // Rotate proxy: close browser, relaunch with different proxy
                    var oldProxy = proxyList[proxyIndex];
                    proxyIndex = (proxyIndex + ConcurrentBrowsers) % proxyList.Count;
                    Console.Error.WriteLine(
                        $"[worker-{workerId}] {consecutiveFailures} consecutive failures — " +
                        $"swapping proxy {oldProxy.Host}:{oldProxy.Port} → " +
                        $"{proxyList[proxyIndex].Host}:{proxyList[proxyIndex].Port}");

                    try { if (browser != null) await browser.CloseAsync(); } catch { }
                    (browser, page) = await LaunchBrowser(pw, proxyIndex);
                    consecutiveFailures = 0;
                }

                // Re-queue failed work so it gets retried
                workQueue.Enqueue(work);
            }

            await Task.Delay(DelayBetweenRequestsMs, cts.Token);
        }
    }
    catch (OperationCanceledException) { /* shutdown */ }
    catch (Exception ex)
    {
        Console.Error.WriteLine($"[worker-{workerId}] Fatal: {ex.Message}");
    }
    finally
    {
        if (browser != null) await browser.CloseAsync();
        pw?.Dispose();
    }
}, cts.Token)).ToArray();

try
{
    await Task.WhenAll(workers);
    Console.Error.WriteLine($"\n[done] Scraped {totalResults} results total");

    // TODO: Export results
    // await using var finalDb = new ScraperDb(DbPath);
    // var count = await CsvExporter.ExportAsync(finalDb.Set<YourEntity>(), "output.csv");
}
catch (OperationCanceledException)
{
    Console.Error.WriteLine("[shutdown] Interrupted. Progress saved — rerun to resume.");
}

// --- 7. Scrape function (customize for your target) ---

async Task<List<YourEntity>> ScrapeWorkItem(IPage page, WorkItem work, CancellationToken ct)
{
    var allResults = new List<YourEntity>();

    // Navigate to the target URL
    var url = $"{BaseUrl}/{work.Category}";
    await page.GotoAsync(url, new() { WaitUntil = WaitUntilState.DOMContentLoaded, Timeout = 30000 });

    // --- WAF / challenge detection ---
    var title = await page.TitleAsync();
    if (title.Contains("WAF", StringComparison.OrdinalIgnoreCase) ||
        title.Contains("Just a moment", StringComparison.OrdinalIgnoreCase) ||
        title.Contains("Checking your browser", StringComparison.OrdinalIgnoreCase))
    {
        try
        {
            // Wait for the challenge to resolve (title changes when done)
            await page.WaitForFunctionAsync(
                "() => !document.title.includes('WAF') && " +
                "!document.title.includes('Just a moment') && " +
                "!document.title.includes('Checking')",
                null,
                new() { Timeout = 30000 });
        }
        catch
        {
            Console.Error.WriteLine($"  [warn] Challenge not resolved for {url}");
            return allResults;
        }
    }

    // Small delay for dynamic content to settle
    await page.WaitForTimeoutAsync(1500);

    // --- Extract data ---

    // Option A: Extract __NEXT_DATA__ (Next.js sites)
    var json = await page.EvaluateAsync<string?>("""
        (() => {
            const el = document.getElementById('__NEXT_DATA__');
            return el ? el.textContent : null;
        })()
    """);

    if (json != null)
    {
        using var doc = JsonDocument.Parse(json);
        var root = doc.RootElement;

        if (root.TryGetProperty("props", out var props) &&
            props.TryGetProperty("pageProps", out var pageProps) &&
            pageProps.TryGetProperty("data", out var data) &&
            data.TryGetProperty("items", out var items))
        {
            foreach (var item in items.EnumerateArray())
            {
                allResults.Add(new YourEntity
                {
                    // Map JSON fields to your entity
                    // Id = item.GetProp("id"),
                    // Name = item.GetProp("name"),
                });
            }
        }
    }

    // Option B: Extract via DOM evaluation (non-Next.js sites)
    // var results = await page.EvalOnSelectorAllAsync<List<Dictionary<string, string>>>(
    //     ".item-card",
    //     "cards => cards.map(c => ({ name: c.querySelector('.title')?.textContent }))");

    // Option C: Intercept XHR responses (see headless-browser.md reference)

    return allResults;
}

// --- Models ---

record ProxyInfo(string Host, int Port, string? User, string? Pass);

record WorkItem(string Category, string Key);

// Replace with your actual entity
public class YourEntity
{
    public int Id { get; set; }
    // Add your fields here
}

// --- JSON helper ---

static class JsonExt
{
    public static string GetProp(this JsonElement el, string name)
        => el.TryGetProperty(name, out var v) ? v.GetString() ?? "" : "";
}
