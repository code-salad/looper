using System.Text.RegularExpressions;

namespace Scraper.Helpers;

/// <summary>
/// Generates randomized browser-like HTTP headers to avoid fingerprint detection.
/// Headers are internally consistent (sec-ch-ua version matches User-Agent).
///
/// <para><b>Important:</b> Update the version numbers in <see cref="UserAgents"/>
/// periodically to match current browser releases. Outdated versions are the #1
/// fingerprinting signal for bot detection systems.</para>
/// </summary>
public static partial class Headers
{
    // --- UPDATE THESE periodically to match current stable releases ---
    // Check: https://chromiumdash.appspot.com/releases
    //        https://www.mozilla.org/en-US/firefox/releases/
    //        https://developer.apple.com/documentation/safari-release-notes

    private static readonly string[] UserAgents =
    [
        // Chrome (Windows)
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36",
        // Chrome (macOS)
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36",
        // Chrome (Linux)
        "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36",
        // Firefox (Windows)
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:135.0) Gecko/20100101 Firefox/135.0",
        // Firefox (macOS)
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:135.0) Gecko/20100101 Firefox/135.0",
        // Safari (macOS)
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.3 Safari/605.1.15",
        // Edge (Windows)
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36 Edg/134.0.0.0",
    ];

    private static readonly string[] AcceptLanguages =
    [
        "en-US,en;q=0.9",
        "en-GB,en;q=0.9",
        "de-DE,de;q=0.9,en;q=0.8",
        "fr-FR,fr;q=0.9,en;q=0.8",
        "es-ES,es;q=0.9,en;q=0.8",
        "en-US,en;q=0.9,de;q=0.7",
    ];

    /// <summary>
    /// Apply randomized browser-like headers to an <see cref="HttpRequestMessage"/>.
    /// Call this before sending each request.
    /// </summary>
    /// <param name="request">The request to modify.</param>
    /// <param name="domain">
    /// Origin domain for Origin/Referer headers.
    /// If null, derived from the request URI.
    /// </param>
    public static void Randomize(HttpRequestMessage request, string? domain = null)
    {
        domain ??= request.RequestUri?.Host ?? "example.com";
        var ua = Pick(UserAgents);

        // --- Core headers every browser sends ---
        request.Headers.TryAddWithoutValidation("User-Agent", ua);
        request.Headers.TryAddWithoutValidation("Accept", "application/json, text/plain, */*");
        request.Headers.TryAddWithoutValidation("Accept-Language", Pick(AcceptLanguages));
        request.Headers.TryAddWithoutValidation("Accept-Encoding", "gzip, deflate, br");
        request.Headers.TryAddWithoutValidation("Connection", "keep-alive");
        request.Headers.TryAddWithoutValidation("DNT", "1");
        request.Headers.TryAddWithoutValidation("Origin", $"https://{domain}");
        request.Headers.TryAddWithoutValidation("Referer", $"https://{domain}/");

        // --- Chromium sec-ch-ua headers (Chrome and Edge) ---
        if (ua.Contains("Chrome"))
        {
            var chromeVer = ChromeVersionRegex().Match(ua).Groups[1].Value;

            if (ua.Contains("Edg"))
            {
                var edgeVer = EdgeVersionRegex().Match(ua).Groups[1].Value;
                request.Headers.TryAddWithoutValidation("sec-ch-ua",
                    $"\"Not A(Brand\";v=\"99\", \"Microsoft Edge\";v=\"{edgeVer}\", \"Chromium\";v=\"{chromeVer}\"");
            }
            else
            {
                request.Headers.TryAddWithoutValidation("sec-ch-ua",
                    $"\"Not A(Brand\";v=\"99\", \"Google Chrome\";v=\"{chromeVer}\", \"Chromium\";v=\"{chromeVer}\"");
            }

            request.Headers.TryAddWithoutValidation("sec-ch-ua-mobile", "?0");
            request.Headers.TryAddWithoutValidation("sec-ch-ua-platform",
                ua.Contains("Windows") ? "\"Windows\"" :
                ua.Contains("Mac") ? "\"macOS\"" : "\"Linux\"");
        }

        // --- sec-fetch-* headers (all modern browsers) ---
        if (ua.Contains("Chrome") || ua.Contains("Firefox"))
        {
            request.Headers.TryAddWithoutValidation("sec-fetch-dest", "empty");
            request.Headers.TryAddWithoutValidation("sec-fetch-mode", "cors");
            request.Headers.TryAddWithoutValidation("sec-fetch-site", "same-origin");
        }

        // --- Random cache-control (some browsers send it, some don't) ---
        if (Random.Shared.Next(2) == 0)
        {
            request.Headers.TryAddWithoutValidation("Cache-Control", "no-cache");
            request.Headers.TryAddWithoutValidation("Pragma", "no-cache");
        }
    }

    /// <summary>
    /// Set Content-Type to application/json if the request has a body
    /// and no Content-Type is already set.
    /// </summary>
    public static void EnsureJsonContentType(HttpRequestMessage request)
    {
        if (request.Content is not null && request.Content.Headers.ContentType is null)
            request.Content.Headers.ContentType =
                new System.Net.Http.Headers.MediaTypeHeaderValue("application/json");
    }

    private static T Pick<T>(T[] arr) => arr[Random.Shared.Next(arr.Length)];

    [GeneratedRegex(@"Chrome/(\d+)")]
    private static partial Regex ChromeVersionRegex();

    [GeneratedRegex(@"Edg/(\d+)")]
    private static partial Regex EdgeVersionRegex();
}
