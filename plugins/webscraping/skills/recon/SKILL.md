---
name: recon
user-invocable: false
argument-hint: "[domain]"
description: Domain reconnaissance skill. Discovers subdomains, API endpoints, tech stack, auth requirements, and anti-bot signals for a target domain. Produces a structured markdown report with recommended scraping approach. Use before building a scraper to find what data sources exist.
allowed-tools: Bash(curl:*), Bash(uvx:*), Bash(subfinder:*), Bash(httpx:*), Bash(katana:*), Bash(go install:*), Bash(amass:*), Bash(mkdir:*), Bash(sort:*), Bash(jq:*), Bash(pip install:*), WebFetch, WebSearch, Read, Write, Grep, Glob
---

# Domain Reconnaissance Playbook

Run all phases in order. Maximize parallelism — independent tools MUST run as parallel Bash calls in a single message.

Save all raw data to `recon/<domain>/` and the final report to `recon/<domain>-report.md`.

---

## Tool Installation

Install Go tools if not already present (check with `which` first):

```bash
# ProjectDiscovery suite
go install -v github.com/projectdiscovery/subfinder/v2/cmd/subfinder@latest
go install -v github.com/projectdiscovery/httpx/cmd/httpx@latest
go install -v github.com/projectdiscovery/katana/cmd/katana@latest

# Python tools (theHarvester, waymore) use uvx — no install needed
```

---

## Phase 1: Quick Passive Checks

Run ALL of these as **parallel Bash/WebFetch calls in one message**:

```
┌──────────────────────────────────────────────────────┐
│              PARALLEL PASSIVE CHECKS                  │
│                                                       │
│  curl: robots.txt                                     │
│  curl: sitemap.xml                                    │
│  curl: sitemap_index.xml                              │
│  curl: /api/                                          │
│  curl: /api/v1/                                       │
│  curl: /api/v2/                                       │
│  curl: /graphql (POST introspection query)            │
│  curl: /rest/                                         │
│  curl: /_next/data/                                   │
│  curl: /wp-json/                                      │
│  curl: /swagger.json                                  │
│  curl: /openapi.json                                  │
│  curl: /api-docs                                      │
│  curl: /docs                                          │
│  curl: /.well-known/                                  │
│  curl: /feed/                                         │
│  WebSearch: "site:<domain> api"                       │
│  WebSearch: "<domain> api documentation developer"    │
│  WebSearch: "<domain> scraper github"                 │
└──────────────────────────────────────────────────────┘
```

For each curl check, use `-sS -o /dev/null -w "%{http_code}"` first to check status, then fetch the body if 2xx/3xx.

Also probe common API subdomains:
- `api.<domain>`
- `data.<domain>`
- `feeds.<domain>`
- `public-api.<domain>`
- `gateway.<domain>`
- `services.<domain>`

Refer to `${CLAUDE_PLUGIN_ROOT}/skills/recon/references/common-paths.md` for the full list of paths and patterns.

**Save results to:** `recon/<domain>/passive-checks.txt`

---

## Phase 2: Subdomain Discovery

Run these tools **in parallel**:

### 2A. theHarvester (OSINT — subdomains, IPs, emails)
```bash
mkdir -p recon/<domain>
uvx theHarvester -d <domain> -b all -l 500 -f recon/<domain>/harvester
```

### 2B. subfinder (50+ passive sources)
```bash
subfinder -d <domain> -all -o recon/<domain>/subfinder-subs.txt
```

### 2C. crt.sh (Certificate Transparency — no install needed)
```bash
curl -s "https://crt.sh/?q=%25.<domain>&output=json" | jq -r '.[].name_value' | sort -u > recon/<domain>/crtsh-subs.txt
```

### 2D. amass (OWASP — passive mode first, active if needed)
```bash
amass enum -passive -d <domain> -o recon/<domain>/amass-subs.txt
```

**After all complete** — merge and dedupe:
```bash
sort -u recon/<domain>/subfinder-subs.txt \
       recon/<domain>/crtsh-subs.txt \
       recon/<domain>/amass-subs.txt \
       <(grep -oP '[\w.-]+\.<domain>' recon/<domain>/harvester.json 2>/dev/null) \
       > recon/<domain>/all-subdomains.txt
echo "[recon] $(wc -l < recon/<domain>/all-subdomains.txt) unique subdomains found"
```

**Save results to:** `recon/<domain>/all-subdomains.txt`

---

## Phase 3: Historical URL Mining

Run these **in parallel** with Phase 2 (they are independent):

### 3A. waymore (Wayback Machine + Common Crawl + URLScan)
```bash
uvx waymore -i <domain> -mode U -oU recon/<domain>/waymore-urls.txt
```

### 3B. gau (GetAllUrls — Wayback, Common Crawl, OTX, URLScan)
```bash
# Install if needed: go install github.com/lc/gau/v2/cmd/gau@latest
gau <domain> > recon/<domain>/gau-urls.txt 2>/dev/null || true
```

### 3C. waybackurls
```bash
# Install if needed: go install github.com/tomnomnom/waybackurls@latest
waybackurls <domain> > recon/<domain>/waybackurls.txt 2>/dev/null || true
```

**After all complete** — merge and filter for API paths:
```bash
sort -u recon/<domain>/waymore-urls.txt \
       recon/<domain>/gau-urls.txt \
       recon/<domain>/waybackurls.txt \
       2>/dev/null > recon/<domain>/all-historical-urls.txt

# Filter for likely API/data endpoints
grep -iE '(/api/|/v[0-9]/|/graphql|/rest/|/data/|\.json|/feed/|/export|/search\?|/query\?|/webhook|/callback)' \
  recon/<domain>/all-historical-urls.txt > recon/<domain>/api-urls.txt 2>/dev/null || true

echo "[recon] $(wc -l < recon/<domain>/all-historical-urls.txt) historical URLs found"
echo "[recon] $(wc -l < recon/<domain>/api-urls.txt) likely API URLs found"
```

**Save results to:** `recon/<domain>/all-historical-urls.txt`, `recon/<domain>/api-urls.txt`

---

## Phase 4: Live Endpoint Probing

Depends on Phases 2 & 3 completing. Run httpx on all discovered subdomains and interesting endpoints.

### 4A. Probe subdomains for live hosts
```bash
httpx -l recon/<domain>/all-subdomains.txt -sc -ct -title -tech-detect -o recon/<domain>/live-subdomains.txt
```

### 4B. Filter for JSON/API-serving endpoints
```bash
httpx -l recon/<domain>/all-subdomains.txt -mc 200,301,302 -ct -match-string "application/json" -o recon/<domain>/json-endpoints.txt
```

### 4C. Probe historical API URLs that are still live
```bash
httpx -l recon/<domain>/api-urls.txt -sc -ct -o recon/<domain>/live-api-urls.txt 2>/dev/null || true
```

Run 4A, 4B, and 4C in parallel.

**Save results to:** `recon/<domain>/live-subdomains.txt`, `recon/<domain>/json-endpoints.txt`, `recon/<domain>/live-api-urls.txt`

---

## Phase 5: JS Bundle Analysis

Find API routes, hardcoded keys, and hidden endpoints embedded in JavaScript bundles.

### 5A. katana JS crawl
```bash
katana -u https://<domain> -d 2 -jc -kf all -ef css,png,jpg,gif,svg,woff,woff2,ttf -o recon/<domain>/katana-js.txt
```

`-jc` enables JavaScript parsing to extract endpoints from JS files. `-kf all` keeps all discovered form/link/script references.

### 5B. Extract API routes from JS bundles

After katana finds JS file URLs, download and search them:

```bash
# Extract JS file URLs from katana output
grep -iE '\.js(\?|$)' recon/<domain>/katana-js.txt > recon/<domain>/js-files.txt 2>/dev/null || true

# Download and search each JS file for API patterns
while IFS= read -r jsurl; do
  curl -sS "$jsurl" 2>/dev/null | grep -oE '"/(api|v[0-9]|graphql|rest|data|auth|users?|search|query|endpoint)[^"]*"' >> recon/<domain>/js-api-routes.txt 2>/dev/null
done < recon/<domain>/js-files.txt
sort -u -o recon/<domain>/js-api-routes.txt recon/<domain>/js-api-routes.txt 2>/dev/null || true
```

### 5C. Search for hardcoded secrets and config in JS

```bash
# Search JS bundles for interesting patterns
while IFS= read -r jsurl; do
  curl -sS "$jsurl" 2>/dev/null | grep -oiE '(apiKey|api_key|apiSecret|baseUrl|base_url|endpoint|Authorization|Bearer|token)["\s:=]+["\x27][^"\x27]{8,}["\x27]' >> recon/<domain>/js-secrets.txt 2>/dev/null
done < recon/<domain>/js-files.txt
sort -u -o recon/<domain>/js-secrets.txt recon/<domain>/js-secrets.txt 2>/dev/null || true
```

### 5D. LinkFinder (optional — if katana misses endpoints)

```bash
# Install: pip install linkfinder
# Run on discovered JS files
while IFS= read -r jsurl; do
  python3 -m linkfinder -i "$jsurl" -o cli >> recon/<domain>/linkfinder-results.txt 2>/dev/null
done < recon/<domain>/js-files.txt
```

**Save results to:** `recon/<domain>/js-api-routes.txt`, `recon/<domain>/js-secrets.txt`

---

## Phase 6: Deep Crawl (Only If Needed)

Only run this phase if Phases 1-5 haven't found sufficient API endpoints or data sources. A deep crawl is slow and generates a lot of data.

```bash
katana -u https://<domain> -d 5 -jc -kf all -aff -o recon/<domain>/deep-crawl.txt
```

Flags:
- `-d 5` — crawl depth 5
- `-jc` — parse JavaScript
- `-kf all` — keep all form/link references
- `-aff` — automatically follow redirects to other subdomains found

Filter the deep crawl for API endpoints:
```bash
grep -iE '(/api/|/v[0-9]/|/graphql|/rest/|/data/|\.json|/feed/)' \
  recon/<domain>/deep-crawl.txt >> recon/<domain>/api-urls.txt
sort -u -o recon/<domain>/api-urls.txt recon/<domain>/api-urls.txt
```

---

## Phase 7: Analysis & Structured Report

After all discovery phases complete, analyze findings and generate a comprehensive markdown report.

### Endpoint Classification

Classify each discovered endpoint:

| Signal | Classification | Scraping Approach |
|--------|---------------|-------------------|
| JSON response, no auth headers required | **Unguarded API** | Direct HTTP fetch — easiest |
| JSON response, requires cookie/session | **Session-gated** | Establish session first, then fetch |
| JSON response, requires Bearer/API key | **Key-gated** | Check if key is in frontend JS bundles |
| HTML response, server-rendered | **HTML target** | Parse with AngleSharp/BeautifulSoup |
| HTML response, client-rendered (SPA) | **SPA target** | Browser automation (Playwright) |
| GraphQL endpoint | **GraphQL API** | Flexible queries, check complexity limits |
| 403/429 on first request | **Anti-bot active** | Residential proxies, browser automation |
| Cloudflare/Akamai challenge page | **WAF protected** | Browser + stealth, residential proxies |

### Tech Stack Detection

Look for these signals in response headers and HTML:

| Header/Pattern | Indicates |
|---------------|-----------|
| `x-powered-by: Next.js` | Next.js — check `__NEXT_DATA__` for embedded JSON |
| `x-powered-by: Nuxt` | Nuxt.js — check `__NUXT_DATA__` |
| `server: cloudflare` | Cloudflare CDN/WAF |
| `server: AkamaiGHost` | Akamai CDN/WAF |
| `x-shopify-stage` | Shopify store |
| `x-wp-*` headers | WordPress — check `/wp-json/` API |
| `cf-ray` header | Behind Cloudflare |
| `set-cookie: __cf_bm` | Cloudflare bot management |
| `<script id="__NEXT_DATA__">` | Next.js with embedded page data |
| `window.__INITIAL_STATE__` | Redux/Vuex with embedded state |

### Generate Report

Write the final report to `recon/<domain>-report.md` with this structure:

```markdown
# Recon Report: <domain>

**Date:** <date>
**Analyst:** Claude Code (recon skill)

## Summary

- **Subdomains found:** N
- **Live hosts:** N
- **API endpoints discovered:** N
- **Tech stack:** [detected technologies]
- **Anti-bot signals:** [none | Cloudflare | Akamai | custom WAF | ...]
- **Recommended approach:** [Direct API | HTML parsing | Browser automation]

## Subdomains

| Subdomain | Status | Content-Type | Title | Technologies |
|-----------|--------|-------------|-------|-------------|
| (from httpx output) |

## API Endpoints

### Unguarded APIs (Tier 1 — best targets)
- `GET https://api.example.com/v1/...` — JSON, no auth
- ...

### Session-Gated APIs (Tier 2)
- `GET https://example.com/api/...` — requires session cookie
- ...

### Key-Gated APIs (Tier 3)
- `GET https://example.com/api/...` — requires API key (found in JS: yes/no)
- ...

### GraphQL Endpoints
- `POST https://example.com/graphql` — introspection enabled: yes/no
- ...

## Historical URLs of Interest

(Notable URLs from Wayback Machine / Common Crawl that suggest data endpoints)

## JS Bundle Findings

- API routes found in JavaScript: [list]
- Hardcoded keys/tokens: [list, redacted]
- Base URLs: [list]

## Tech Stack

| Component | Value |
|-----------|-------|
| Framework | Next.js / Nuxt / Rails / Django / ... |
| CDN/WAF | Cloudflare / Akamai / none |
| Server | nginx / Apache / ... |
| Database hints | (from API response patterns) |

## Auth Requirements

| Endpoint | Auth Type | Details |
|----------|-----------|---------|
| /api/v1/public | None | Open access |
| /api/v1/user | Bearer token | JWT, obtained from /auth/login |
| ... | ... | ... |

## Anti-Bot Signals

| Signal | Severity | Details |
|--------|----------|---------|
| Cloudflare | High | cf-ray header present, __cf_bm cookie |
| Rate limiting | Medium | 429 after N requests |
| ... | ... | ... |

## Recommended Scraping Approach

Based on the findings above:

1. **Primary target:** [best endpoint found]
2. **Method:** [Direct API / HTML parsing / Browser automation]
3. **Auth strategy:** [none / session / key from JS / ...]
4. **Proxy recommendation:** [datacenter / residential / none]
5. **Estimated difficulty:** [easy / medium / hard]
6. **Key risks:** [rate limiting / anti-bot / auth complexity / ...]
```

### Save Raw Data

Ensure all raw data files are saved in `recon/<domain>/`:
- `passive-checks.txt` — Phase 1 results
- `all-subdomains.txt` — merged subdomains
- `all-historical-urls.txt` — merged historical URLs
- `api-urls.txt` — filtered API URLs
- `live-subdomains.txt` — httpx probe results
- `json-endpoints.txt` — JSON-serving endpoints
- `live-api-urls.txt` — live historical API URLs
- `js-files.txt` — discovered JS bundle URLs
- `js-api-routes.txt` — API routes from JS
- `js-secrets.txt` — hardcoded config from JS
- Individual tool outputs (harvester, subfinder, crtsh, amass, waymore, gau, waybackurls, katana)

---

## Parallelism Summary

```
┌─────────────────────────────────────────────────────────────┐
│  Phase 1: Passive Checks          (all parallel)            │
│  Phase 2: Subdomain Discovery     (all parallel)            │  ← Run Phases 1-3
│  Phase 3: Historical URL Mining   (all parallel)            │    concurrently
├─────────────────────────────────────────────────────────────┤
│  Phase 4: Live Probing            (depends on 2+3)          │  ← Sequential gate
├─────────────────────────────────────────────────────────────┤
│  Phase 5: JS Bundle Analysis      (depends on 4)            │  ← Sequential gate
├─────────────────────────────────────────────────────────────┤
│  Phase 6: Deep Crawl              (only if needed)          │  ← Conditional
├─────────────────────────────────────────────────────────────┤
│  Phase 7: Analysis & Report       (depends on all above)    │  ← Final
└─────────────────────────────────────────────────────────────┘
```

Phases 1, 2, and 3 are fully independent — launch ALL their tools as parallel Bash calls in a single message. Phase 4 waits for 2+3 to complete (needs subdomain and URL lists). Phase 5 waits for katana output. Phase 6 is conditional. Phase 7 is always last.

---

## Multi-Domain Recon

When running recon on multiple domains, spawn one Task subagent per domain:

```
Task(general-purpose): "Run /recon on domain-a.com"
Task(general-purpose): "Run /recon on domain-b.com"
Task(general-purpose): "Run /recon on domain-c.com"
```

Each subagent runs its own parallel recon pipeline independently.

---

## Instructions

After reading this playbook, begin reconnaissance on the target domain.
1. Create the output directory `recon/<domain>/`.
2. Run Phases 1-3 with maximum parallelism.
3. Proceed through Phases 4-7 sequentially as results become available.
4. Write the final report to `recon/<domain>-report.md`.
5. Present the key findings (summary + recommended approach) to the user.

## Target

$ARGUMENTS
