# Pagination Patterns Reference

## Pattern 1: Page Number Pagination (Parallelizable)

The most common pattern. Each page is independently addressable via `?page=N`.

```csharp
// Discover total pages from first request
using var firstPage = await FetchPage(1, ct);
var totalPages = firstPage.RootElement.GetProperty("total_pages").GetInt32();
// OR: calculate from total count
var totalItems = firstPage.RootElement.GetProperty("total").GetInt32();
var pageSize = 50;
var totalPages2 = (int)Math.Ceiling((double)totalItems / pageSize);

// Fan out all pages in parallel
var concurrency = Math.Max(1, pool.AvailableCount);
using var semaphore = new SemaphoreSlim(concurrency);
var tasks = new List<Task>();

for (var page = 2; page <= totalPages; page++)
{
    var key = ScraperDb.MakeKey("page", page);
    if (await db.IsCompletedAsync(key, ct)) continue;

    await semaphore.WaitAsync(ct);
    var p = page;
    tasks.Add(Task.Run(async () =>
    {
        try
        {
            using var data = await FetchPage(p, ct);
            await ProcessAndStore(data, ct);
            await db.CompleteWorkAsync(key, ct);
        }
        finally { semaphore.Release(); }
    }, ct));
}
await Task.WhenAll(tasks);
```

## Pattern 2: Offset/Limit Pagination (Parallelizable)

Uses `?offset=N&limit=M` instead of page numbers. Same parallel strategy.

```csharp
var limit = 100;
var totalItems = 5000; // from first response

for (var offset = 0; offset < totalItems; offset += limit)
{
    var key = ScraperDb.MakeKey("offset", offset);
    if (await db.IsCompletedAsync(key, ct)) continue;

    await semaphore.WaitAsync(ct);
    var currentOffset = offset;
    tasks.Add(Task.Run(async () =>
    {
        try
        {
            var url = $"https://api.example.com/items?offset={currentOffset}&limit={limit}";
            var data = await Fetch(url, ct);
            await ProcessAndStore(data, ct);
            await db.CompleteWorkAsync(key, ct);
        }
        finally { semaphore.Release(); }
    }, ct));
}
```

## Pattern 3: Cursor-Based Pagination (Sequential Only)

Each response includes a cursor/token needed for the next request. Cannot parallelize.

```csharp
string? cursor = null;
var pageNum = 0;

// Resume from saved progress
var progress = await db.GetProgressAsync("cursor-scrape");
if (progress is not null)
{
    cursor = progress.Extra;
    pageNum = progress.LastPage;
    Console.Error.WriteLine($"[resume] From page {pageNum}, cursor={cursor}");
}

while (true)
{
    ct.ThrowIfCancellationRequested();
    pageNum++;

    var url = cursor is null
        ? "https://api.example.com/items?limit=100"
        : $"https://api.example.com/items?limit=100&after={cursor}";

    var response = await pool.ExecuteAsync(async (client, innerCt) =>
    {
        var req = new HttpRequestMessage(HttpMethod.Get, url);
        Headers.Randomize(req);
        var resp = await client.SendAsync(req, innerCt);
        resp.EnsureSuccessStatusCode();
        return await resp.Content.ReadFromJsonAsync<CursorResponse>(innerCt);
    }, ct);

    if (response?.Items is null or { Count: 0 }) break;

    await db.AddBatchAsync(response.Items.Select(MapToEntity), ct);

    cursor = response.NextCursor;
    await db.UpdateProgressAsync("cursor-scrape", pageNum, extra: cursor, ct: ct);

    if (cursor is null) break; // last page
}

await db.CompleteWorkAsync("cursor-scrape", ct);

record CursorResponse(List<ItemDto> Items, string? NextCursor);
```

## Pattern 4: Keyset Pagination (Sequential, but Stable)

Uses the last item's sort key (e.g., `?after_id=123&limit=100`). More stable than offset pagination for large datasets.

```csharp
string? lastId = null;
var totalFetched = 0;

// Resume from saved progress
var progress = await db.GetProgressAsync("keyset-scrape");
if (progress is not null)
{
    lastId = progress.Extra;
    totalFetched = progress.LastPage;
}

while (true)
{
    var url = lastId is null
        ? "https://api.example.com/items?limit=100&sort=id"
        : $"https://api.example.com/items?limit=100&sort=id&after_id={lastId}";

    var items = await Fetch<List<Item>>(url, ct);
    if (items is null or { Count: 0 }) break;

    await db.AddBatchAsync(items.Select(MapToEntity), ct);

    lastId = items[^1].Id; // last item's ID
    totalFetched += items.Count;
    await db.UpdateProgressAsync("keyset-scrape", totalFetched, extra: lastId, ct: ct);

    if (items.Count < 100) break; // partial page = last page
}
```

## Pattern 5: Infinite Scroll (Browser Required)

Content loads dynamically as user scrolls. Requires browser automation.

```csharp
var allItems = new List<ItemData>();
var seenIds = new HashSet<string>();
var maxScrollAttempts = 100;
var noNewDataCount = 0;

for (var i = 0; i < maxScrollAttempts; i++)
{
    // Extract current items
    var items = await page.EvalOnSelectorAllAsync<List<ItemData>>(
        ".item-card",
        "cards => cards.map(c => ({ id: c.dataset.id, name: c.querySelector('.name')?.textContent }))"
    );

    var newItems = items.Where(item => seenIds.Add(item.Id)).ToList();
    allItems.AddRange(newItems);

    if (newItems.Count == 0)
    {
        noNewDataCount++;
        if (noNewDataCount >= 3) break; // 3 scrolls with no new data = done
    }
    else
    {
        noNewDataCount = 0;
    }

    // Scroll down
    await page.EvaluateAsync("window.scrollTo(0, document.body.scrollHeight)");
    await page.WaitForTimeoutAsync(Random.Shared.Next(1500, 3000));

    // Check for "Load more" button
    var loadMore = await page.QuerySelectorAsync("button.load-more");
    if (loadMore is not null)
    {
        await loadMore.ClickAsync();
        await page.WaitForTimeoutAsync(2000);
    }

    Console.Error.WriteLine($"[scroll] {i + 1}, total unique items: {allItems.Count}");
}
```

## Pattern 6: "Load More" Button

Similar to infinite scroll but requires clicking a button.

```csharp
var allItems = new List<ItemData>();

while (true)
{
    // Extract current items
    var items = await page.EvalOnSelectorAllAsync<List<ItemData>>(".item", "...");
    allItems.AddRange(items);

    // Look for load more button
    var loadMoreBtn = await page.QuerySelectorAsync("[data-testid='load-more'], .load-more, button:has-text('Load More')");
    if (loadMoreBtn is null) break; // no more pages

    // Check if button is disabled
    var isDisabled = await loadMoreBtn.GetAttributeAsync("disabled");
    if (isDisabled is not null) break;

    await loadMoreBtn.ClickAsync();

    // Wait for new content to load
    var previousCount = items.Count;
    await page.WaitForFunctionAsync(
        $"document.querySelectorAll('.item').length > {allItems.Count}",
        null,
        new PageWaitForFunctionOptions { Timeout = 10000 }
    );
}
```

## Pattern 7: GraphQL Pagination

GraphQL APIs often use cursor-based or connection-based pagination.

```csharp
// Relay-style cursor pagination
string? endCursor = null;
var hasNextPage = true;

while (hasNextPage)
{
    var query = new
    {
        query = @"
            query GetItems($after: String) {
                items(first: 100, after: $after) {
                    pageInfo {
                        hasNextPage
                        endCursor
                    }
                    edges {
                        node {
                            id
                            name
                            price
                        }
                    }
                }
            }
        ",
        variables = new { after = endCursor },
    };

    var response = await pool.ExecuteAsync(async (client, ct) =>
    {
        var req = new HttpRequestMessage(HttpMethod.Post, "https://api.example.com/graphql");
        req.Content = JsonContent.Create(query);
        Headers.Randomize(req);
        var resp = await client.SendAsync(req, ct);
        resp.EnsureSuccessStatusCode();
        return await resp.Content.ReadFromJsonAsync<GraphQLResponse>(ct);
    }, ct);

    var connection = response!.Data.Items;
    hasNextPage = connection.PageInfo.HasNextPage;
    endCursor = connection.PageInfo.EndCursor;

    var items = connection.Edges.Select(e => e.Node);
    await db.AddBatchAsync(items.Select(MapToEntity), ct);

    await db.UpdateProgressAsync("graphql-scrape", pageNum++, extra: endCursor, ct: ct);
}
```

## Pattern 8: Multi-Level Pagination (Category → Items)

First paginate through categories, then paginate items within each.

```csharp
// Level 1: Get all categories
var categories = await FetchAllCategories(ct);

foreach (var category in categories)
{
    var categoryKey = ScraperDb.MakeKey("category", category.Id);
    if (await db.IsCompletedAsync(categoryKey, ct)) continue;

    // Level 2: Paginate items within this category
    var progress = await db.GetProgressAsync(categoryKey);
    var startPage = progress?.LastPage ?? 0;

    for (var page = startPage + 1; ; page++)
    {
        var url = $"https://api.example.com/categories/{category.Id}/items?page={page}";
        var items = await Fetch<PagedResponse>(url, ct);

        if (items?.Data is null or { Count: 0 }) break;

        await db.AddBatchAsync(items.Data.Select(MapToEntity), ct);
        await db.UpdateProgressAsync(categoryKey, page, items.TotalPages, ct: ct);

        if (page >= items.TotalPages) break;
    }

    await db.CompleteWorkAsync(categoryKey, ct);
    Console.Error.WriteLine($"[progress] Category {category.Name} complete");
}
```

## Choosing the Right Pattern

| API Signals | Pattern | Parallelizable |
|-------------|---------|----------------|
| `?page=1&page=2` | Page number | Yes |
| `?offset=0&limit=100` | Offset/limit | Yes |
| Response has `nextCursor` or `next_token` | Cursor | No |
| Response has `after_id` or `since_id` | Keyset | No |
| No API, content loads on scroll | Infinite scroll | No |
| GraphQL with `pageInfo.endCursor` | GraphQL cursor | No |
| Multiple nested levels | Multi-level | Outer: depends, Inner: depends |

### Maximizing throughput for sequential pagination

When stuck with cursor-based pagination, maximize per-request throughput:
1. Request the maximum `limit` the API allows
2. Use the proxy pool so each sequential request uses a different IP (LRU rotation)
3. Minimize delay between requests — the cursor dependency is the bottleneck, not rate limits
