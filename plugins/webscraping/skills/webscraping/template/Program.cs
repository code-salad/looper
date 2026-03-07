using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using Microsoft.EntityFrameworkCore;
using Polly;
using Polly.Retry;
using Scraper.Data;
using Scraper.Helpers;
using Scraper.Services;

// ============================================================================
// SCRAPER TEMPLATE — Customize this file for your target.
//
// Steps:
//   1. Define your response model and DB entity below
//   2. Register the entity in ScraperDb (add DbSet + OnModelCreating)
//   3. Adjust ProxyPoolOptions for your target's rate limits
//   4. Update FetchPage() with your target's URL, method, and body
//   5. Run: dotnet run
// ============================================================================

// --- 1. Configuration ---

var proxyPool = await ProxyPool.LoadAsync("proxies.txt", new ProxyPoolOptions
{
    MinRequestInterval = TimeSpan.FromSeconds(8),   // 1 req per 8s per proxy
    MaxConsecutiveFailures = 10,                     // blacklist after 10 failures
    BaseBlacklistDuration = TimeSpan.FromMinutes(5), // 5min → 10min → 20min → ...
    MaxBlacklistDuration = TimeSpan.FromHours(2),    // cap at 2 hours
    RequestTimeout = TimeSpan.FromSeconds(30),
});

await using var db = ScraperDb.Create("data.db");
await db.Database.EnsureCreatedAsync();

// --- 2. Polly retry pipeline (respects Retry-After headers) ---

var retryPipeline = new ResiliencePipelineBuilder<HttpResponseMessage>()
    .AddRetry(new RetryStrategyOptions<HttpResponseMessage>
    {
        ShouldHandle = new PredicateBuilder<HttpResponseMessage>()
            .HandleResult(r => r.StatusCode is
                HttpStatusCode.TooManyRequests or
                HttpStatusCode.BadGateway or
                HttpStatusCode.ServiceUnavailable or
                HttpStatusCode.GatewayTimeout)
            .Handle<HttpRequestException>()
            .Handle<TaskCanceledException>(),
        MaxRetryAttempts = 5,
        BackoffType = DelayBackoffType.Exponential,
        Delay = TimeSpan.FromSeconds(2),
        UseJitter = true,
        DelayGenerator = args =>
        {
            // Respect Retry-After header from the server
            if (args.Outcome.Result?.Headers.RetryAfter?.Delta is { } delta)
                return ValueTask.FromResult<TimeSpan?>(delta);
            return ValueTask.FromResult<TimeSpan?>(null); // use default backoff
        },
        OnRetry = args =>
        {
            var status = args.Outcome.Result?.StatusCode;
            Console.Error.WriteLine(
                $"[retry] Attempt {args.AttemptNumber + 1}/5, " +
                $"status={status}, delay={args.RetryDelay.TotalSeconds:F1}s");
            return ValueTask.CompletedTask;
        },
    })
    .Build();

// --- 3. Graceful shutdown ---

using var cts = new CancellationTokenSource();
Console.CancelKeyPress += (_, e) =>
{
    e.Cancel = true;
    Console.Error.WriteLine("\n[shutdown] Ctrl+C received, finishing current requests...");
    cts.Cancel();
};

// --- 4. Fetch function (customize for your target) ---

async Task<JsonDocument> FetchPage(int page, CancellationToken ct)
{
    return await proxyPool.ExecuteAsync(async (client, innerCt) =>
    {
        var request = new HttpRequestMessage(HttpMethod.Post, "https://api.example.com/data")
        {
            Content = JsonContent.Create(new { page, pageSize = 50 }),
        };
        Headers.Randomize(request, "example.com");
        Headers.EnsureJsonContentType(request);

        var response = await retryPipeline.ExecuteAsync(
            async _ => await client.SendAsync(request, innerCt),
            innerCt);

        response.EnsureSuccessStatusCode();

        // Validate content type
        var contentType = response.Content.Headers.ContentType?.MediaType ?? "";
        if (!contentType.Contains("json"))
        {
            var preview = (await response.Content.ReadAsStringAsync(innerCt))[..200];
            throw new InvalidOperationException(
                $"Expected JSON but got {contentType}: {preview}");
        }

        return await JsonDocument.ParseAsync(
            await response.Content.ReadAsStreamAsync(innerCt), cancellationToken: innerCt);
    }, ct);
}

// --- 5. Orchestrator (customize for your scraping pattern) ---

try
{
    // Discover total pages from first request
    using var firstPage = await FetchPage(1, cts.Token);
    var totalPages = firstPage.RootElement.GetProperty("total_pages").GetInt32();
    Console.Error.WriteLine($"[scraper] Total pages: {totalPages}");

    // Process page 1
    // TODO: Extract and store data from firstPage

    // Fan out remaining pages across proxies
    var concurrency = Math.Max(1, proxyPool.AvailableCount);
    using var semaphore = new SemaphoreSlim(concurrency);
    var tasks = new List<Task>();

    for (var page = 2; page <= totalPages; page++)
    {
        cts.Token.ThrowIfCancellationRequested();

        var key = ScraperDb.MakeKey("page", page);
        if (await db.IsCompletedAsync(key, cts.Token))
            continue;

        await semaphore.WaitAsync(cts.Token);
        var currentPage = page;

        tasks.Add(Task.Run(async () =>
        {
            try
            {
                using var data = await FetchPage(currentPage, cts.Token);

                // TODO: Parse data.RootElement and extract your entities
                // var items = data.RootElement.GetProperty("items").EnumerateArray()
                //     .Select(e => new YourEntity { ... });
                // await db.AddBatchAsync(items, cts.Token);

                await db.CompleteWorkAsync(key, cts.Token);

                // Progress reporting
                var stats = proxyPool.GetStats();
                Console.Error.WriteLine(
                    $"[scraper] Page {currentPage}/{totalPages} done | " +
                    $"Proxies: {stats.Available}/{stats.Total} available");
            }
            catch (OperationCanceledException) { /* shutdown */ }
            catch (AllProxiesBlacklistedException)
            {
                Console.Error.WriteLine(
                    $"[scraper] Page {currentPage} deferred — all proxies blacklisted");
                // The proxy pool has expiry; the orchestrator could retry later
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine(
                    $"[scraper] Page {currentPage} failed: {ex.Message}");
            }
            finally
            {
                semaphore.Release();
            }
        }, cts.Token));
    }

    await Task.WhenAll(tasks);

    // --- 6. Export ---
    // var count = await CsvExporter.ExportAsync(db.Set<YourEntity>(), "output.csv", ct: cts.Token);
    // Console.Error.WriteLine($"[export] Wrote {count} rows to output.csv");

    var finalStats = proxyPool.GetStats();
    Console.Error.WriteLine(
        $"\n[done] Successes: {finalStats.TotalSuccesses}, " +
        $"Failures: {finalStats.TotalFailures}, " +
        $"Blacklisted: {finalStats.Blacklisted}");
}
catch (OperationCanceledException)
{
    Console.Error.WriteLine("[shutdown] Scrape interrupted. Progress saved — rerun to resume.");
}
finally
{
    await proxyPool.DisposeAsync();
}
