# Data Extraction Patterns

## Pattern 1: JSON API Response

The cleanest data source. Deserialize directly to typed models.

```csharp
// Strongly typed deserialization
var response = await pool.ExecuteAsync(async (client, ct) =>
{
    var req = new HttpRequestMessage(HttpMethod.Get, "https://api.example.com/products?page=1");
    Headers.Randomize(req);
    var resp = await client.SendAsync(req, ct);
    resp.EnsureSuccessStatusCode();
    return await resp.Content.ReadFromJsonAsync<ApiResponse>(ct);
}, ct);

record ApiResponse(List<ProductDto> Data, int TotalPages, int TotalItems);
record ProductDto(string Id, string Name, decimal Price, string? Category, string? ImageUrl);
```

### Handling inconsistent JSON (missing fields, wrong types)

```csharp
var options = new JsonSerializerOptions
{
    PropertyNameCaseInsensitive = true,
    NumberHandling = JsonNumberHandling.AllowReadingFromString, // "123" → 123
    DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
};

// Use JsonDocument for dynamic/unpredictable structures
using var doc = await JsonDocument.ParseAsync(stream);
var root = doc.RootElement;

// Safe extraction with fallbacks
var name = root.TryGetProperty("name", out var nameProp) ? nameProp.GetString() : null;
var price = root.TryGetProperty("price", out var priceProp)
    ? priceProp.ValueKind == JsonValueKind.Number ? priceProp.GetDecimal()
    : priceProp.ValueKind == JsonValueKind.String ? decimal.TryParse(priceProp.GetString(), out var p) ? p : 0
    : 0
    : 0;
```

## Pattern 2: HTML Table Extraction

Common for directory sites, government data, legacy sites.

```csharp
using AngleSharp.Html.Parser;

var parser = new HtmlParser();
var document = await parser.ParseDocumentAsync(html);

// Extract table rows
var table = document.QuerySelector("table.data-table");
var headers = table!.QuerySelectorAll("thead th")
    .Select(th => th.TextContent.Trim().ToLowerInvariant())
    .ToList();

var rows = table.QuerySelectorAll("tbody tr").Select(tr =>
{
    var cells = tr.QuerySelectorAll("td").Select(td => td.TextContent.Trim()).ToList();
    var dict = new Dictionary<string, string>();
    for (var i = 0; i < Math.Min(headers.Count, cells.Count); i++)
        dict[headers[i]] = cells[i];
    return dict;
}).ToList();

// Map to entities
var entities = rows.Select(row => new Product
{
    Name = row.GetValueOrDefault("product name", ""),
    Price = decimal.TryParse(row.GetValueOrDefault("price", "")
        .Replace("$", "").Replace(",", ""), out var p) ? p : 0,
    Category = row.GetValueOrDefault("category", ""),
}).ToList();
```

## Pattern 3: Embedded JSON in HTML (SSR Sites)

Next.js, Nuxt.js, and similar SSR frameworks embed structured data in the HTML.

```csharp
// Next.js __NEXT_DATA__
var nextDataScript = document.QuerySelector("script#__NEXT_DATA__");
if (nextDataScript is not null)
{
    using var nextData = JsonDocument.Parse(nextDataScript.TextContent);
    var pageProps = nextData.RootElement
        .GetProperty("props")
        .GetProperty("pageProps");

    // Extract data from the SSR payload
    var products = pageProps.GetProperty("products").Deserialize<List<ProductDto>>();
}

// Nuxt.js __NUXT__
var nuxtScript = document.QuerySelectorAll("script")
    .FirstOrDefault(s => s.TextContent.Contains("__NUXT__"));
if (nuxtScript is not null)
{
    // Nuxt embeds as JS assignment, need to extract the JSON part
    var match = Regex.Match(nuxtScript.TextContent, @"__NUXT__\s*=\s*(\{.+\})");
    if (match.Success)
    {
        // Note: Nuxt payload may contain JS functions, not pure JSON
        // May need a JS parser or browser evaluation
    }
}

// Generic JSON-LD structured data
var jsonLdScripts = document.QuerySelectorAll("script[type='application/ld+json']");
foreach (var script in jsonLdScripts)
{
    using var jsonLd = JsonDocument.Parse(script.TextContent);
    var type = jsonLd.RootElement.GetProperty("@type").GetString();
    if (type == "Product")
    {
        var name = jsonLd.RootElement.GetProperty("name").GetString();
        var price = jsonLd.RootElement.GetProperty("offers").GetProperty("price").GetString();
    }
}
```

## Pattern 4: CSS Selector Extraction

For server-rendered HTML without embedded JSON.

```csharp
// Product listing page
var products = document.QuerySelectorAll(".product-card").Select(card =>
{
    return new Product
    {
        Name = card.QuerySelector("h2.title, .product-name, [data-testid='name']")
            ?.TextContent.Trim() ?? "",

        Price = ParsePrice(card.QuerySelector(".price, .product-price, [data-price]")
            ?.TextContent),

        Url = card.QuerySelector("a[href]")?.GetAttribute("href") ?? "",

        ImageUrl = card.QuerySelector("img")?.GetAttribute("src")
            ?? card.QuerySelector("img")?.GetAttribute("data-src"), // lazy-loaded

        Rating = ParseRating(card.QuerySelector(".rating, .stars")?.GetAttribute("aria-label")),

        InStock = card.QuerySelector(".out-of-stock, .sold-out") is null,
    };
}).ToList();

// Helper: parse "$1,234.56" → 1234.56
static decimal ParsePrice(string? text)
{
    if (string.IsNullOrWhiteSpace(text)) return 0;
    var cleaned = Regex.Replace(text, @"[^\d.]", "");
    return decimal.TryParse(cleaned, out var p) ? p : 0;
}

// Helper: parse "4.5 out of 5 stars" → 4.5
static double ParseRating(string? text)
{
    if (string.IsNullOrWhiteSpace(text)) return 0;
    var match = Regex.Match(text, @"([\d.]+)");
    return match.Success && double.TryParse(match.Value, out var r) ? r : 0;
}
```

## Pattern 5: XHR/Fetch Interception (Browser)

Capture API calls the frontend makes internally.

```csharp
var capturedData = new ConcurrentBag<JsonDocument>();

page.Response += async (_, response) =>
{
    var url = response.Url;

    // Capture specific API patterns
    if ((url.Contains("/api/") || url.Contains("/graphql")) &&
        response.Status == 200 &&
        response.Headers.ContainsKey("content-type") &&
        response.Headers["content-type"].Contains("json"))
    {
        try
        {
            var body = await response.BodyAsync();
            var doc = JsonDocument.Parse(body);
            capturedData.Add(doc);
            Console.Error.WriteLine($"[intercept] Captured: {url} ({body.Length} bytes)");
        }
        catch { /* non-JSON response */ }
    }
};

// Trigger the page to make API calls
await page.GotoAsync("https://example.com/products");
await page.WaitForLoadStateAsync(LoadState.NetworkIdle);

// Process captured data
foreach (var doc in capturedData)
{
    // Extract items from the captured API responses
}
```

## Pattern 6: Multi-Format Extraction (Adapting to Unknown Sites)

When you don't know the data format in advance.

```csharp
async Task<List<Dictionary<string, string>>> ExtractProducts(string html)
{
    var document = await new HtmlParser().ParseDocumentAsync(html);

    // Strategy 1: Try JSON-LD
    var jsonLd = document.QuerySelector("script[type='application/ld+json']");
    if (jsonLd is not null)
    {
        try
        {
            var ld = JsonDocument.Parse(jsonLd.TextContent);
            if (ld.RootElement.TryGetProperty("@type", out var type) &&
                type.GetString() is "Product" or "ItemList")
            {
                return ExtractFromJsonLd(ld);
            }
        }
        catch { }
    }

    // Strategy 2: Try __NEXT_DATA__
    var nextData = document.QuerySelector("script#__NEXT_DATA__");
    if (nextData is not null)
    {
        return ExtractFromNextData(nextData.TextContent);
    }

    // Strategy 3: Try common CSS patterns
    var selectors = new[]
    {
        ".product-card", ".product-item", ".item-card",
        "[data-product]", "[data-item]", ".listing-item",
        "article.product", "li.product",
    };

    foreach (var selector in selectors)
    {
        var items = document.QuerySelectorAll(selector);
        if (items.Length > 0)
        {
            return items.Select(ExtractFromElement).ToList();
        }
    }

    // Strategy 4: Fall back to table extraction
    var tables = document.QuerySelectorAll("table");
    if (tables.Length > 0)
    {
        return ExtractFromTable(tables[0]);
    }

    return new List<Dictionary<string, string>>();
}
```

## Data Cleaning Utilities

```csharp
static class DataCleaner
{
    // Remove HTML tags from text
    public static string StripHtml(string html)
        => Regex.Replace(html, "<[^>]+>", "").Trim();

    // Normalize whitespace
    public static string NormalizeWhitespace(string text)
        => Regex.Replace(text.Trim(), @"\s+", " ");

    // Extract numbers from text
    public static decimal? ExtractDecimal(string? text)
    {
        if (string.IsNullOrWhiteSpace(text)) return null;
        var match = Regex.Match(text, @"[\d,]+\.?\d*");
        if (!match.Success) return null;
        return decimal.TryParse(match.Value.Replace(",", ""), out var d) ? d : null;
    }

    // Parse dates in various formats
    public static DateTime? ParseDate(string? text)
    {
        if (string.IsNullOrWhiteSpace(text)) return null;
        string[] formats = { "yyyy-MM-dd", "MM/dd/yyyy", "dd/MM/yyyy",
            "MMM dd, yyyy", "MMMM dd, yyyy", "yyyy-MM-ddTHH:mm:ss" };
        return DateTime.TryParseExact(text.Trim(), formats, null,
            System.Globalization.DateTimeStyles.None, out var d) ? d : null;
    }

    // Resolve relative URLs
    public static string ResolveUrl(string? relativeUrl, string baseUrl)
    {
        if (string.IsNullOrWhiteSpace(relativeUrl)) return "";
        if (Uri.TryCreate(relativeUrl, UriKind.Absolute, out _)) return relativeUrl;
        return new Uri(new Uri(baseUrl), relativeUrl).ToString();
    }

    // Deduplicate by key
    public static List<T> DeduplicateBy<T, TKey>(IEnumerable<T> items, Func<T, TKey> keySelector)
        => items.GroupBy(keySelector).Select(g => g.First()).ToList();
}
```
