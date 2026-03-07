# Common API Paths & Detection Patterns

Reference file for the recon skill. Use these patterns during Phase 1 (passive checks) and Phase 7 (analysis).

---

## Standard Paths to Probe

### Sitemaps & Robots
```
/robots.txt
/sitemap.xml
/sitemap_index.xml
/sitemaps/sitemap.xml
```

### REST API Paths
```
/api
/api/
/api/v1/
/api/v2/
/api/v3/
/rest/
/data/
/public/api/
/external/api/
/mobile/api/
/app/api/
```

### GraphQL
```
/graphql
/graphql/
/gql
/query
/api/graphql
/v1/graphql
```

GraphQL introspection query:
```json
{"query": "{ __schema { types { name } } }"}
```

Full introspection (if simple one works):
```json
{"query": "{ __schema { queryType { name } types { name kind fields { name type { name kind ofType { name } } } } } }"}
```

### OpenAPI / Swagger
```
/swagger.json
/swagger/v1/swagger.json
/openapi.json
/openapi.yaml
/api-docs
/api-docs/
/docs
/docs/
/swagger-ui/
/swagger-ui/index.html
/redoc
/api/docs
/api/swagger.json
/v1/api-docs
/v2/api-docs
```

### Framework-Specific

#### Next.js
```
/_next/data/                     # Data routes (build ID needed)
/_next/data/<buildId>/<page>.json
```
Look for `<script id="__NEXT_DATA__">` in HTML — contains page props as JSON.

#### Nuxt.js
```
/_nuxt/
/__nuxt/
```
Look for `window.__NUXT_DATA__` or `window.__NUXT__` in HTML.

#### WordPress
```
/wp-json/
/wp-json/wp/v2/
/wp-json/wp/v2/posts
/wp-json/wp/v2/pages
/wp-json/wp/v2/categories
/wp-json/wp/v2/tags
/wp-json/wp/v2/users
/wp-json/wp/v2/media
/wp-json/wp/v2/search?search=<term>
/wp-json/wc/v3/                  # WooCommerce
/?rest_route=/wp/v2/posts        # Alternative REST route
/xmlrpc.php                      # Legacy XML-RPC
```

#### Django / Django REST Framework
```
/api/
/api/v1/
/api/v2/
/api-auth/
/admin/
```

#### Rails
```
/api/
/api/v1/
/rails/info/routes               # Route listing (dev mode)
```

#### Laravel
```
/api/
/api/v1/
/sanctum/csrf-cookie             # Laravel Sanctum
/oauth/token                     # Laravel Passport
```

#### ASP.NET
```
/api/
/odata/
/signalr/
/_blazor
```

#### Shopify
```
/products.json
/collections.json
/cart.json
/search/suggest.json?q=<term>
/admin/api/2024-01/              # Admin API (auth required)
```

### Authentication Endpoints
```
/auth/
/auth/login
/auth/token
/auth/refresh
/oauth/token
/oauth/authorize
/login
/signin
/api/auth/
/api/login
/.well-known/openid-configuration
```

### Common Data Endpoints
```
/feed/
/feed/atom
/feed/rss
/rss
/rss.xml
/atom.xml
/export
/download
/search?q=<term>
/autocomplete?q=<term>
/suggest?q=<term>
```

### Well-Known Paths
```
/.well-known/
/.well-known/openid-configuration
/.well-known/security.txt
/.well-known/change-password
/.well-known/assetlinks.json      # Android app links
/.well-known/apple-app-site-association  # iOS app links
```

### Common API Subdomains
```
api.<domain>
data.<domain>
feeds.<domain>
public-api.<domain>
gateway.<domain>
services.<domain>
rest.<domain>
graphql.<domain>
search.<domain>
cdn.<domain>
static.<domain>
assets.<domain>
media.<domain>
admin.<domain>
app.<domain>
mobile.<domain>
m.<domain>
```

---

## Tech Stack Detection Signatures

### Response Headers

| Header | Value Pattern | Indicates |
|--------|--------------|-----------|
| `x-powered-by` | `Next.js` | Next.js (check `__NEXT_DATA__`) |
| `x-powered-by` | `Nuxt`, `Nuxt.js` | Nuxt.js (check `__NUXT_DATA__`) |
| `x-powered-by` | `Express` | Node.js Express |
| `x-powered-by` | `PHP/*` | PHP backend |
| `x-powered-by` | `ASP.NET` | .NET backend |
| `server` | `cloudflare` | Cloudflare CDN/WAF |
| `server` | `AkamaiGHost` | Akamai CDN/WAF |
| `server` | `nginx` | Nginx web server |
| `server` | `Apache` | Apache web server |
| `server` | `Vercel` | Vercel hosting (likely Next.js) |
| `server` | `Netlify` | Netlify hosting |
| `x-shopify-stage` | any | Shopify store |
| `x-wp-total` | any | WordPress REST API |
| `x-wp-totalpages` | any | WordPress REST API |
| `x-drupal-cache` | any | Drupal CMS |
| `x-generator` | `Drupal *` | Drupal CMS |
| `x-aspnet-version` | any | ASP.NET |
| `x-aspnetmvc-version` | any | ASP.NET MVC |
| `cf-ray` | any | Behind Cloudflare |
| `cf-cache-status` | any | Cloudflare caching |
| `x-amz-cf-id` | any | AWS CloudFront |
| `x-cache` | `Hit from cloudfront` | AWS CloudFront cache hit |
| `x-vercel-cache` | any | Vercel edge cache |

### HTML Body Patterns

| Pattern | Indicates |
|---------|-----------|
| `<script id="__NEXT_DATA__">` | Next.js with embedded page data |
| `window.__NEXT_DATA__` | Next.js hydration data |
| `window.__NUXT__` | Nuxt.js state |
| `window.__NUXT_DATA__` | Nuxt 3 state |
| `window.__INITIAL_STATE__` | Redux/Vuex embedded state |
| `window.__APOLLO_STATE__` | Apollo GraphQL cache |
| `window.__RELAY_STORE__` | Relay GraphQL cache |
| `window._sharedData` | Instagram-style embedded data |
| `<div id="__next">` | Next.js app root |
| `<div id="app">` or `<div id="root">` | React/Vue SPA |
| `ng-app` or `ng-version` | Angular |
| `data-reactroot` | React |
| `<meta name="generator" content="WordPress">` | WordPress |
| `<meta name="generator" content="Shopify">` | Shopify |

### JS Bundle Patterns (search with grep)

| Pattern | Indicates |
|---------|-----------|
| `"baseUrl"` or `"baseURL"` | API base URL configuration |
| `"apiKey"` or `"api_key"` | Hardcoded API key |
| `"apiSecret"` or `"api_secret"` | Hardcoded API secret |
| `"Authorization"` | Auth header construction |
| `"Bearer "` | JWT token usage |
| `"/api/v"` | API versioned routes |
| `"graphql"` | GraphQL endpoint reference |
| `fetch(` or `axios.` | HTTP client calls |
| `"x-api-key"` | Custom API key header |
| `process.env.` or `import.meta.env.` | Environment variable references |

---

## Anti-Bot Detection Signals

### HTTP Response Signals

| Signal | Severity | Indicates |
|--------|----------|-----------|
| `server: cloudflare` + `cf-ray` header | High | Cloudflare protection |
| `set-cookie: __cf_bm` | High | Cloudflare bot management active |
| `set-cookie: cf_clearance` | Very High | Cloudflare challenge required |
| `server: AkamaiGHost` | High | Akamai bot detection |
| `set-cookie: _abck` | Very High | Akamai bot manager active |
| `set-cookie: bm_sz` | High | Akamai sensor data |
| `x-datadome` header | High | DataDome anti-bot |
| `set-cookie: datadome` | Very High | DataDome active |
| HTTP 403 on first request | High | Blocked by WAF/anti-bot |
| HTTP 429 on first request | Medium | Aggressive rate limiting |
| HTTP 503 with challenge page | High | JS challenge required |
| `<title>Just a moment...</title>` | Very High | Cloudflare challenge page |
| `<title>Access Denied</title>` | High | WAF block page |
| `<noscript>` with redirect | Medium | JS requirement (may indicate anti-bot) |

### JavaScript Challenge Indicators

| Pattern | Indicates |
|---------|-----------|
| `turnstile` in HTML | Cloudflare Turnstile CAPTCHA |
| `hcaptcha` in HTML | hCaptcha challenge |
| `recaptcha` in HTML | Google reCAPTCHA |
| `challenge-platform` in HTML | Cloudflare challenge |
| `_cf_chl_opt` in HTML | Cloudflare challenge options |
| `window._phantom` or `window.__nightmare` checks | Headless browser detection |
| Canvas fingerprinting scripts | Browser fingerprinting |
| WebGL fingerprinting | Hardware fingerprinting |

### Request Header Checks (what anti-bot systems look for)

| Check | What They Verify |
|-------|-----------------|
| User-Agent consistency | UA string matches TLS fingerprint and JS navigator |
| sec-ch-ua consistency | Chromium brand/version matches User-Agent |
| Accept-Language presence | Missing = bot signal |
| Referer chain | Direct requests without referrer = suspicious |
| Cookie jar | No cookies after initial visit = suspicious |
| TLS fingerprint (JA3/JA4) | Matches known browser fingerprint |
| HTTP/2 settings frame | Matches browser implementation |
| Header order | Browsers send headers in consistent order |

---

## API URL Pattern Filter

Use this regex to filter URLs for likely API/data endpoints:

```bash
grep -iE '(/api/|/v[0-9]/|/graphql|/rest/|/data/|\.json(\?|$)|/feed/|/export|/search\?|/query\?|/webhook|/callback|/oauth|/token|/auth/|/rss|/atom|/sitemap|/suggest|/autocomplete)'
```
