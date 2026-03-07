# Authenticated Scraping Patterns

## Pattern 1: Cookie-Based Session Authentication

Most common for traditional web applications.

```csharp
// Login and maintain session cookies automatically
var handler = new HttpClientHandler
{
    CookieContainer = new CookieContainer(),
    UseCookies = true,
};
using var client = new HttpClient(handler);

// Login
var loginContent = new FormUrlEncodedContent(new Dictionary<string, string>
{
    ["email"] = "user@example.com",
    ["password"] = "password123",
    ["_csrf"] = csrfToken, // if needed
});

var loginResponse = await client.PostAsync("https://example.com/login", loginContent);
loginResponse.EnsureSuccessStatusCode();

// Session cookies are now stored in CookieContainer
// Subsequent requests include them automatically
var dataResponse = await client.GetAsync("https://example.com/api/protected-data");
```

### Extracting CSRF tokens

```csharp
// Fetch login page to get CSRF token
var loginPage = await client.GetStringAsync("https://example.com/login");
var parser = new HtmlParser();
var document = await parser.ParseDocumentAsync(loginPage);
var csrfToken = document.QuerySelector("input[name='_csrf']")?.GetAttribute("value")
    ?? document.QuerySelector("meta[name='csrf-token']")?.GetAttribute("content");
```

### Saving and restoring cookies

```csharp
// Save cookies to file for reuse across runs
void SaveCookies(CookieContainer container, string domain, string path)
{
    var cookies = container.GetCookies(new Uri($"https://{domain}"));
    var data = cookies.Cast<Cookie>().Select(c => new
    {
        c.Name, c.Value, c.Domain, c.Path, c.Expires, c.Secure, c.HttpOnly
    });
    File.WriteAllText(path, JsonSerializer.Serialize(data));
}

// Restore cookies
void LoadCookies(CookieContainer container, string path)
{
    if (!File.Exists(path)) return;
    var cookies = JsonSerializer.Deserialize<List<CookieData>>(File.ReadAllText(path));
    foreach (var c in cookies!)
    {
        container.Add(new Cookie(c.Name, c.Value, c.Path, c.Domain)
        {
            Expires = c.Expires,
            Secure = c.Secure,
            HttpOnly = c.HttpOnly,
        });
    }
}
```

## Pattern 2: Bearer Token / JWT Authentication

Common for modern APIs and SPAs.

```csharp
// Obtain token
var tokenResponse = await client.PostAsJsonAsync("https://api.example.com/auth/login", new
{
    email = "user@example.com",
    password = "password123",
});

var tokenResult = await tokenResponse.Content.ReadFromJsonAsync<TokenResponse>();
var accessToken = tokenResult!.AccessToken;
var refreshToken = tokenResult.RefreshToken;
var expiresAt = DateTime.UtcNow.AddSeconds(tokenResult.ExpiresIn);

// Use token for subsequent requests
async Task<HttpResponseMessage> AuthenticatedRequest(string url, CancellationToken ct)
{
    // Auto-refresh if expired
    if (DateTime.UtcNow >= expiresAt.AddMinutes(-5))
    {
        await RefreshAccessToken();
    }

    var request = new HttpRequestMessage(HttpMethod.Get, url);
    request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", accessToken);
    Headers.Randomize(request);
    return await client.SendAsync(request, ct);
}

async Task RefreshAccessToken()
{
    var refreshResponse = await client.PostAsJsonAsync("https://api.example.com/auth/refresh", new
    {
        refresh_token = refreshToken,
    });
    var result = await refreshResponse.Content.ReadFromJsonAsync<TokenResponse>();
    accessToken = result!.AccessToken;
    expiresAt = DateTime.UtcNow.AddSeconds(result.ExpiresIn);
    Console.Error.WriteLine("[auth] Token refreshed");
}

record TokenResponse(string AccessToken, string RefreshToken, int ExpiresIn);
```

## Pattern 3: API Key Authentication

```csharp
// API key in header
var request = new HttpRequestMessage(HttpMethod.Get, "https://api.example.com/data");
request.Headers.TryAddWithoutValidation("X-API-Key", apiKey);

// API key in query string
var request2 = new HttpRequestMessage(HttpMethod.Get,
    $"https://api.example.com/data?api_key={apiKey}&page={page}");

// Rotating multiple API keys to distribute rate limits
var apiKeys = File.ReadAllLines("api-keys.txt")
    .Where(l => !string.IsNullOrWhiteSpace(l) && !l.StartsWith('#'))
    .ToArray();
var keyIndex = 0;

string GetNextApiKey() => apiKeys[Interlocked.Increment(ref keyIndex) % apiKeys.Length];
```

## Pattern 4: OAuth 2.0 Client Credentials

For APIs that require OAuth authentication.

```csharp
// Client credentials flow (server-to-server)
var tokenRequest = new FormUrlEncodedContent(new Dictionary<string, string>
{
    ["grant_type"] = "client_credentials",
    ["client_id"] = clientId,
    ["client_secret"] = clientSecret,
    ["scope"] = "read:data",
});

var tokenResponse = await client.PostAsync("https://auth.example.com/oauth/token", tokenRequest);
var token = await tokenResponse.Content.ReadFromJsonAsync<OAuthTokenResponse>();
```

## Pattern 5: Browser Login → Cookie Extraction → HttpClient

When the login flow is complex (CAPTCHA, MFA, OAuth redirect).

```csharp
using Microsoft.Playwright;

// Use browser for the complex login flow
using var playwright = await Playwright.CreateAsync();
await using var browser = await playwright.Chromium.LaunchAsync(new BrowserTypeLaunchOptions
{
    Headless = false, // Show browser so user can solve CAPTCHA/MFA
});

var context = await browser.NewContextAsync();
var page = await context.NewPageAsync();

await page.GotoAsync("https://example.com/login");
Console.Error.WriteLine("[auth] Please login in the browser window...");

// Wait for successful login (detect by URL change or cookie presence)
await page.WaitForURLAsync("**/dashboard**", new PageWaitForURLOptions
{
    Timeout = 120000, // 2 minutes for manual login
});

Console.Error.WriteLine("[auth] Login detected, extracting cookies...");

// Extract cookies
var cookies = await context.CookiesAsync();

// Transfer to HttpClient
var handler = new HttpClientHandler { CookieContainer = new CookieContainer() };
foreach (var cookie in cookies)
{
    handler.CookieContainer.Add(new Cookie(cookie.Name, cookie.Value, cookie.Path, cookie.Domain)
    {
        Secure = cookie.Secure,
        HttpOnly = cookie.HttpOnly,
    });
}
using var httpClient = new HttpClient(handler);

// Save cookies for next run
SaveCookies(handler.CookieContainer, "example.com", "session-cookies.json");

// Now scrape with HttpClient (fast) using browser cookies
await browser.CloseAsync(); // close browser, no longer needed
```

## Pattern 6: Session Rotation (Multiple Accounts)

When you need multiple sessions to scale.

```csharp
// Load multiple sessions
var sessions = new List<(HttpClient Client, string AccountId)>();
foreach (var creds in accounts)
{
    var handler = new HttpClientHandler { CookieContainer = new CookieContainer() };
    var client = new HttpClient(handler);

    // Login with this account
    var loginResp = await client.PostAsJsonAsync("https://example.com/api/login", new
    {
        email = creds.Email,
        password = creds.Password,
    });

    if (loginResp.IsSuccessStatusCode)
    {
        sessions.Add((client, creds.Email));
        Console.Error.WriteLine($"[auth] Logged in as {creds.Email}");
    }
}

// Round-robin across sessions
var sessionIndex = 0;
var (sessionClient, _) = sessions[Interlocked.Increment(ref sessionIndex) % sessions.Count];
```

## Security Best Practices

| Practice | Why |
|----------|-----|
| Store credentials in environment variables or separate config | Never hardcode in source |
| Use `.gitignore` for cookie files and API key files | Prevent accidental commits |
| Encrypt saved sessions at rest | Protect against disk access |
| Rotate credentials periodically | Limit exposure window |
| Use read-only API keys when possible | Minimize blast radius |
| Never log tokens or passwords | Keep them out of stderr/stdout |

```csharp
// Load credentials from environment
var email = Environment.GetEnvironmentVariable("SCRAPER_EMAIL")
    ?? throw new Exception("SCRAPER_EMAIL not set");
var password = Environment.GetEnvironmentVariable("SCRAPER_PASSWORD")
    ?? throw new Exception("SCRAPER_PASSWORD not set");
```
