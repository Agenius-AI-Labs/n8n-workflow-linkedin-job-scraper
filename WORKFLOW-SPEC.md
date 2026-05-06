# LinkedIn Job Scraper — Workflow Spec

> **Status:** Production (n8n-dev). Last updated 2026-05-06.
>
> Sanitized of secrets. Replaces the historical `README.md`, which describes an earlier two-workflow split using the `@apify/n8n-nodes-apify` community node.

---

## 1. Overview

A 4-workflow n8n pipeline that scrapes LinkedIn job postings via a custom Apify actor (`mfrostbutter/linkedin-jobs-scraper`), scores them against role-specific keyword sets, dedupes against an Airtable base, and notifies via Slack. Built for Michael Frostbutter's director-and-above job hunt.

**Why four workflows, not one.** Each role family has a distinct keyword universe (Engineer, Architect/Builder, Leadership, Executive). Four workflows let each scope manage its own run guard, budget, and dedup state without contention. Underneath, all four share a byte-identical pipeline; only the `Config` node's keyword list and `workflowScope` differ.

**Why HTTP not the Apify community node.** The `@apify/n8n-nodes-apify` v1 node iterated its input list 2-3× per click in our environment, producing 28 actor calls for 10 input queries. Replaced with a plain `n8n-nodes-base.httpRequest` v4.2 node hitting `https://api.apify.com/v2/acts/.../run-sync-get-dataset-items` directly. Deterministic, one call per query, no community-node black box.

**Why two layers of HTTP batching.** Two unrelated rate limits constrain the system: Apify's per-account memory cap (21,504 MB total — 5 concurrent 4 GB actor runs hit it), and Airtable's per-base rate limit (5 req/s). Both surface silently as `{"errors":[...]}` payloads that pass through `neverError: true`. n8n's HTTP node `options.batching` field solves both — `1 per 5 s` for Apify, `4 per 1.1 s` for Airtable.

---

## 2. The four workflows

| Role family | Workflow ID | Scope tag | URL |
|---|---|---|---|
| Engineer | `Bm173SaYAmBHzgZu` | `role_engineer` | http://10.10.0.80:5679/workflow/Bm173SaYAmBHzgZu |
| Architect / Builder | `qS3FE4gihCXYiJkY` | `role_architect_builder` | http://10.10.0.80:5679/workflow/qS3FE4gihCXYiJkY |
| Leadership | `NXL8LKXq8Yj1PF2b` | `role_leadership` | http://10.10.0.80:5679/workflow/NXL8LKXq8Yj1PF2b |
| Executive | `w92tVFLoK3w40Xig` | `role_executive` | http://10.10.0.80:5679/workflow/w92tVFLoK3w40Xig |

Each workflow holds **10 title keywords**, capped at **10 actor calls per run** by the `Split LinkedIn Queries` node.

### Engineer (10)
AI Automation Engineer · Workflow Automation Engineer · AI Agent Engineer · Intelligent Automation Engineer · Automation Engineer · Process Automation Engineer · AI Workflow Engineer · Automation and AI Agent Engineer · AI Solutions Engineer · Integration Developer

### Architect / Builder (10)
AI Solutions Architect · Automation Solutions Architect · Intelligent Automation Architect · Power Platform Solution Architect · RPA Solution Architect · Integration Architect · Hyperautomation Architect · Principal AI Architect · Forward Deployed Engineer · Pre-Sales Solutions Engineer

### Leadership (10)
Head of AI · Head of Automation · Head of AI Strategy · Director of AI · Director of Intelligent Automation · Director of Automation · Director of AI Platform · Director of Digital Transformation · Director Enterprise AI · Director AI Governance

### Executive (10)
Chief AI Officer · Chief Automation Officer · Chief Digital Officer · VP of AI · VP of Technology · VP of IT and AI · VP of Intelligent Automation · VP of Automation · VP of Data and AI · VP of Engineering AI

---

## 3. End-to-end pipeline

```
Manual Trigger
   ↓
Config                                  ← keyword set + run-guard check
   ↓
Split LinkedIn Queries                  ← cap 10, dedup, budget window
   ↓ (10 items)
Run Apify (HTTP Sync)                   ← batched 1 per 5s
   ↓ (1 dataset response per call, ~15-30 jobs each)
Flatten Apify Dataset                   ← explode array into individual items
   ↓
Normalize LinkedIn                      ← map to unified schema
   ↓
Dedup and Score                         ← in-batch dedup + relevance score
   ↓
Check Airtable Existing                 ← batched 4 per 1.1s
   ↓
Is New Job?  ──── false ───→ Skip Existing
   ↓ true
Create Airtable Record                  ← batched 4 per 1.1s
   ↓
Build Notification                      ← count succeeded / rate-limited / other
   ↓
Has Notifications?  ──── false ───→ (end)
   ↓ true
   ├─→ Send Slack Alert
   └─→ Queue Resume Generation  ──→  Trigger Resume Workflow   (jobs ≥70 only)
```

---

## 4. Per-node settings

Sources: `workflow-role-engineer-http.json` (canonical). All four workflows share identical node settings except `Config`.

### 4.1 Manual Trigger

- Type: `n8n-nodes-base.manualTrigger` v1
- Parameters: `{}`

### 4.2 Config

- Type: `n8n-nodes-base.code` v2
- Reads `$env.LINKEDIN_COOKIE` if present
- Writes `staticData.linkedinScraperLastStartMs_<scope>` for the run guard
- Builds `config.linkedinSearches` from cross-product of `roleKeywords × locationPlans × workTypes`, sliced to `maxQueriesPerRun=10`
- Sets `_abortRun: true` if `runGuardMinMinutes` (45) hasn't elapsed

**Key fields (engineer scope shown):**
```js
{
  workflowScope: 'role_engineer',
  locationPlans: [
    { planId: 'ny_remote_hybrid', location: 'New York City Metropolitan Area', workTypes: ['remote', 'hybrid'] },
    { planId: 'us_remote_only',   location: 'United States',                    workTypes: ['remote'] }
  ],
  datePosted: 'past_24h',
  maxResultsPerSearch: 40,
  fetchFullDescription: true,
  enrichWithAI: false,
  linkedinCookie: $env.LINKEDIN_COOKIE || '',
  runGuardEnabled: true,
  runGuardMinMinutes: 45,
  maxQueriesPerRun: 10,
  safeMode: false,           // safe-mode flags retained for emergency reduction
  freshnessDays: 14,
  scoring: { /* see §9 */ },
  airtableBaseId: 'appHQJJBGSLIXybkr',
  airtableTableId: 'tbltkycOY9FgUdQpm',
  slackWebhookUrl: '<SLACK_WEBHOOK_URL>'
}
```

### 4.3 Split LinkedIn Queries

- Type: `n8n-nodes-base.code` v2
- Three guards before emit:
  1. **In-execution guard**: refuses to emit twice for the same `$execution.id` (`splitLastExecutionId_<scope>`).
  2. **Tuple dedup**: drops repeats of `(keywords, location, workType, datePosted, windowId)`.
  3. **Budget window**: 10 actor calls per scope per 15 minutes, persisted in `staticData.splitBudget_<scope>`.
- Final cap: `min(HARD_MAX_QUERIES=10, configuredMax, remainingBudget)`
- Output items carry `_queryIndex`, `_queryCount`, `_config`, `fetchFullDescription`, plus the search tuple

### 4.4 Run Apify (HTTP Sync)

- Type: `n8n-nodes-base.httpRequest` v4.2

```
Method:        POST
URL:           https://api.apify.com/v2/acts/emj1kLbPVetKdfJk8/run-sync-get-dataset-items
Headers:       Content-Type: application/json
Authentication: genericCredentialType → httpHeaderAuth
                (n8n credential: "Apify API (Header)" — stores
                 Authorization: Bearer <APIFY_TOKEN>)
Body (JSON expression):
  {{ (() => {
    const idx = Number($json._queryIndex || 0);
    if (idx > 10) throw new Error(`Safety cap exceeded: query index ${idx} > 10`);
    return {
      keywords:              $json.keywords,
      location:              $json.location,
      workType:              $json.workType,
      datePosted:            $json.datePosted,
      maxResults:            $json.maxResults,
      fetchFullDescription:  $json.fetchFullDescription,
      enrichWithAI:          $json.enrichWithAI,
      linkedinCookie:        $json.linkedinCookie || '',
      proxyConfig:           $json.actorProxyConfig || {},
      _n8nQueryIndex:        idx,
      _n8nQueryCount:        Number($json._queryCount || 0),
      _n8nExecutionId:       String($execution.id || ''),
      _n8nWorkflowScope:     String($json._config?.workflowScope || '')
    };
  })() }}

Options:
  timeout:               300000     # 5 min — Apify sync endpoint may block until actor completes
  batching.batch:        { batchSize: 1, batchInterval: 5000 }   # 1 call per 5s — keeps memory under 4GB
  response.response:     { neverError: true, responseFormat: "json" }
```

**Why `neverError: true`:** Apify returns 200 even for errors like `actor-memory-limit-exceeded` (with the error in the body). Letting n8n auto-throw on those would lose the visibility we get from `Build Notification`'s post-mortem accounting.

### 4.5 Flatten Apify Dataset

- Type: `n8n-nodes-base.code` v2
- The sync endpoint returns an array of dataset items per call. n8n's HTTP node delivers it as `{json: <array>}` (or wrapped). This node explodes it into one n8n item per job.

```js
const out = [];
for (const item of $input.all()) {
  const j = item.json;
  let arr = null;
  if (Array.isArray(j))                 arr = j;
  else if (j && Array.isArray(j.body))  arr = j.body;
  else if (j && Array.isArray(j.data))  arr = j.data;
  else if (j && typeof j === 'object')  arr = [j];
  if (!arr) continue;
  for (const r of arr) {
    if (r && typeof r === 'object') out.push({ json: r });
  }
}
return out;
```

### 4.6 Normalize LinkedIn

- Type: `n8n-nodes-base.code` v2
- Maps actor's 14 fields (see §5) to the unified schema downstream nodes expect.
- Skips records without `title`.
- Carries `_config` forward by re-fetching from the Config node if upstream dropped it.

```js
// Output per job:
{
  jobTitle, company, location, source: 'LinkedIn',
  sourceId,                        // actor 'id' or 'li-<ts>-<rand>' fallback
  sourceUrl,                       // 'link' or 'applyUrl'
  postedDate,
  salaryMin, salaryMax,
  employmentType: 'Full-time',
  workplaceType,                   // 'Remote' | 'Hybrid' | 'On-site'
  companySize: '', companyIndustry: '',
  descriptionSnippet: <first 500 chars>,
  fullDescription: <full text>,
  easyApply: false,
  applicants: null,
  _config
}
```

### 4.7 Dedup and Score

- Type: `n8n-nodes-base.code` v2
- In-batch dedup by `(jobTitle.lower | company.lower)`.
- Scoring rules: see §9.
- After per-job scoring, applies a **dual NY+London office bonus** (+15) retroactively when the same `company` appears once in the NYC metro and once in London — encodes the "international footprint" preference in the role brief.
- Final sort: descending `relevanceScore`.

### 4.8 Check Airtable Existing

- Type: `n8n-nodes-base.httpRequest` v4.2

```
Method:         GET
URL (expr):     https://api.airtable.com/v0/appHQJJBGSLIXybkr/tbltkycOY9FgUdQpm
                  ?filterByFormula=AND({Source ID}="<sourceId>",{Source}="<source>")
Authentication: genericCredentialType → httpHeaderAuth
                (n8n credential stores Authorization: Bearer <AIRTABLE_PAT>)
Options:
  batching.batch:    { batchSize: 4, batchInterval: 1100 }
  response.response: { neverError: true, responseFormat: "json" }
```

### 4.9 Is New Job?

- Type: `n8n-nodes-base.if` v2
- Condition: `{{ $json.error ? -1 : ($json.records ? $json.records.length : 0) }} == 0`
- True branch → `Create Airtable Record`. False branch → `Skip Existing`.
- The `error ? -1` shim ensures Airtable error responses don't accidentally count as "0 records, therefore new" — they short-circuit to `-1` so the `==0` test fails.

### 4.10 Create Airtable Record

- Type: `n8n-nodes-base.httpRequest` v4.2

```
Method:         POST
URL:            https://api.airtable.com/v0/appHQJJBGSLIXybkr/tbltkycOY9FgUdQpm
Headers:        Content-Type: application/json
Authentication: genericCredentialType → httpHeaderAuth (Airtable PAT)

Body (JSON expression — fields pulled from upstream "Dedup and Score"):
  {
    "records": [{
      "fields": {
        "Job Title":           "{{ ...jobTitle }}",
        "Company":             "{{ ...company }}",
        "Location":            "{{ ...location }}",
        "Source":              "{{ ...source.replace(/\"/g, '') }}",
        "Source ID":           "{{ ...sourceId }}",
        "Source URL":          "{{ ...sourceUrl }}",
        "Posted Date":         "{{ ...postedDate.split('T')[0] }}",
        "Salary Min":          {{ ...salaryMin || 'null' }},
        "Salary Max":          {{ ...salaryMax || 'null' }},
        "Employment Type":     "{{ ...employmentType }}",
        "Workplace Type":      "{{ ...workplaceType }}",
        "Company Size":        "{{ ...companySize }}",
        "Company Industry":    "{{ ...companyIndustry }}",
        "Description Snippet": {{ JSON.stringify(...descriptionSnippet) }},
        "Full Description":    {{ JSON.stringify(...fullDescription) }},
        "Relevance Score":     {{ ...relevanceScore }},
        "Score Breakdown":     {{ JSON.stringify(...scoreBreakdown) }},
        "AI Governance Match": {{ ...aiGovernanceMatch }},
        "Status":              "New",
        "Easy Apply":          {{ ...easyApply || false }},
        "Applicants":          {{ ...applicants || 'null' }},
        "First Seen":          "{{ ...firstSeen.split('T')[0] }}",
        "Last Seen":           "{{ ...lastSeen.split('T')[0] }}",
        "Dual Office NY+London": {{ ...dualOfficeNYLondon || false }}
      }
    }]
  }

Options:
  batching.batch:    { batchSize: 4, batchInterval: 1100 }
  response.response: { neverError: true, responseFormat: "json" }
```

### 4.11 Skip Existing

- Type: `n8n-nodes-base.noOp` v1
- Terminus for jobs already in Airtable.

### 4.12 Build Notification

- Type: `n8n-nodes-base.code` v2
- Counts Airtable response items into three buckets:
  - **succeeded**: `records[0].id` present
  - **rateLimited**: `errors[].error` contains `"RATE_LIMIT"`
  - **otherFailed**: any other `errors` or `error` property
- Builds Slack message: clean success or partial-failure breakdown.

```js
let succeeded = 0, rateLimited = 0, otherFailed = 0;
for (const i of items) {
  const j = i.json || {};
  if (j.records?.[0]?.id) succeeded += 1;
  else if (Array.isArray(j.errors) && j.errors.some(e => (e.error||'').includes('RATE_LIMIT'))) rateLimited += 1;
  else if (j.errors || j.error) otherFailed += 1;
}
const total = items.length;
const message = total === 0
  ? 'No new jobs added.'
  : (rateLimited === 0 && otherFailed === 0)
    ? `New jobs have been added to Airtable. (${succeeded})`
    : `Airtable: ${succeeded} added, ${rateLimited} rate-limited, ${otherFailed} other failed (out of ${total}).`;
```

### 4.13 Has Notifications?

- Type: `n8n-nodes-base.if` v2
- Condition: `{{ $json.count }} > 0`
- True branch fans out to Slack alert + resume queue. False ends the run silently.

### 4.14 Send Slack Alert

- Type: `n8n-nodes-base.httpRequest` v4.2

```
Method:   POST
URL:      <SLACK_WEBHOOK_URL>           # passed in from Build Notification
Headers:  Content-Type: application/json
Body:
  {
    "text":           "<message>",
    "mrkdwn":         true,
    "unfurl_links":   false,
    "unfurl_media":   false
  }
Options:
  response.response: { fullResponse: true, neverError: true, responseFormat: "text" }
```

### 4.15 Queue Resume Generation

- Type: `n8n-nodes-base.code` v2
- Filters Airtable response items where `Relevance Score >= 70`.
- For each, emits a payload aimed at the resume-generator webhook.
- **Returns `[]`** when zero qualifying jobs (prevents downstream "URL parameter must be a string, got undefined" crash on the HTTP node).

```js
const items = $('Create Airtable Record').all();
const toGenerate = items.filter(i => (i.json.records?.[0]?.fields?.['Relevance Score'] || 0) >= 70);
if (toGenerate.length === 0) return [];
const webhookUrl = 'https://n8n-dev.ageniuslabs.com/webhook/job-resume-generator';
return toGenerate.map(i => {
  const f = i.json.records?.[0]?.fields || {};
  return { json: {
    airtableRecordId: i.json.records?.[0]?.id || '',
    jobTitle: f['Job Title'], company: f['Company'],
    fullDescription: f['Full Description'],
    sourceUrl: f['Source URL'], source: f['Source'],
    webhookUrl
  }};
});
```

### 4.16 Trigger Resume Workflow

- Type: `n8n-nodes-base.httpRequest` v4.2

```
Method:  POST
URL:     {{ $json.webhookUrl }}        # https://n8n-dev.ageniuslabs.com/webhook/job-resume-generator
Headers: Content-Type: application/json
Body:
  {
    "airtableRecordId": "<id>",
    "jobTitle":         "<title>",
    "company":          "<company>",
    "fullDescription":  "<JD text>",
    "sourceUrl":        "<url>",
    "source":           "LinkedIn"
  }
Options:
  response.response: { neverError: true, responseFormat: "json" }
```

---

## 5. Apify actor I/O contract

**Actor:** `mfrostbutter/linkedin-jobs-scraper` (id `emj1kLbPVetKdfJk8`)

**Sync endpoint:** `POST https://api.apify.com/v2/acts/emj1kLbPVetKdfJk8/run-sync-get-dataset-items`
- Authentication: `Authorization: Bearer <APIFY_TOKEN>`
- Blocks until run completes (or up to 5 min); returns dataset items array directly in body.
- Average runtime per call with `fetchFullDescription: true`: 50–60 s.

### 5.1 Input schema

| Field | Type | Default | Description |
|---|---|---|---|
| `keywords` | string | required | Job title / search terms |
| `location` | string | "United States" | City, state, or country |
| `workType` | enum | "any" | `remote` / `hybrid` / `onsite` / `any` |
| `datePosted` | enum | "past_week" | `past_24h` / `past_week` / `past_month` / `any` |
| `maxResults` | integer | 100 | Cap on records returned |
| `fetchFullDescription` | boolean | true | Fetch full JD per job (one extra request each) |
| `linkedinCookie` | string | "" | `li_at` session cookie (Apify secret) |
| `proxyConfig` | object | {} | Apify proxy settings |

### 5.2 Output schema (14 fields per job)

```json
{
  "id":                  "3862304981",
  "title":               "Director of AI",
  "companyName":         "Acme Corp",
  "location":            "New York, NY, United States",
  "postedAt":            "2026-04-18T00:00:00.000Z",
  "salary":              "$180,000/yr",
  "salary_low":          180000,
  "salary_high":         null,
  "descriptionText":     "We are looking for...",
  "link":                "https://www.linkedin.com/jobs/view/3862304981",
  "applyUrl":            "https://careers.example.com/apply/3862304981",
  "workplaceTypes":      ["Remote"],
  "workRemoteAllowed":   true,
  "source_platform":     "linkedin",
  "scraped_at":          "2026-04-20T12:00:00Z"
}
```

### 5.3 Error envelope (when run fails inside Apify)

```json
{ "error": { "type": "actor-memory-limit-exceeded",
             "message": "By launching this job you will exceed the memory limit of 21504MB..." } }
```

The HTTP node returns 200 even for these. `Flatten Apify Dataset` wraps non-array bodies into a single item, and `Normalize LinkedIn` skips items without `title` — so error envelopes are dropped silently. (We catch them in `Build Notification` only when they happen on the Airtable side.)

---

## 6. Airtable schema

**Base:** `appHQJJBGSLIXybkr` · **Table:** `tbltkycOY9FgUdQpm` (Jobs)

| Field | ID | Type | Set by |
|---|---|---|---|
| Job Title | `fldonWqVT7oGnGEzp` | Text | Scraper ingest |
| Company | `fldFjj2nTDRN9I0Wv` | Text | Scraper ingest |
| Location | `fldimRZm9pHykJylV` | Text | Scraper ingest |
| Source | `fldSySVPgVbuUPQoQ` | Single Select | Scraper ingest |
| Source ID | `fldtBWYVaFt5NGPvm` | Text | Scraper ingest (dedup key) |
| Source URL | `fldsC0jgDbUHtXtCK` | URL | Scraper ingest |
| Score | `fldq7oSZPNl5M5Apf` | Number | Scoring module |
| Breakdown | `fldQFAZiuP5Xx0f4C` | Text | Scoring module |
| Status | `fldJWeHqcM4kRGXJ4` | Single Select | Scraper ingest (default: New) |
| Workplace | `fldnhyPgamNqACoLM` | Text | Scoring module |
| Salary Min | `fldfBjsoZUa0uPlho` | Number | Scoring module |
| Salary Max | `fld6qO1SrO9AffY50` | Number | Scoring module |
| Dual NY+London | `fldkZcQjjvijV7yjE` | Checkbox | Scoring module |
| First Seen | `fld2ZDu8GLkcOAIBg` | Date | Scraper ingest |
| Posted | `fldjEM0hGEOZEGPt6` | Date | Scraper ingest |
| Snippet | `fldz4G72sZMzo7sMc` | Text | Scraper ingest |
| Description | `fldtN1zpFSWUOstFt` | Long Text | Scraper ingest (full JD) |
| **Tier** | `fldiumc2IdR1cHDhu` | Single Select | `classify_tiers.py` (Phase 3) |
| **Package_Created** | `fldvCDm4xutAKTp0Z` | Checkbox | `build_packages.py` |
| **Package_Path** | `fld3YCt60AlbVzBap` | Single Line Text | `build_packages.py` |

> **Field-name drift to fix:** the spec lists this Long Text field as `Description` (id `fldtN1zpFSWUOstFt`) but the n8n workflow's `Create Airtable Record` body writes to a key called `Full Description`. Either (a) Airtable has a second field by that name, or (b) the writes are silently going somewhere unexpected. `build_packages.py` reads the `Description` field — it currently sees whatever non-n8n source last populated it. Reconciliation TODO.

---

## 7. Slack notification format

**Webhook target:** `<SLACK_WEBHOOK_URL>` (Incoming Webhook to a single private channel; URL itself is the credential)

**Body shape (every message):**
```json
{
  "text":           "<message>",
  "mrkdwn":         true,
  "unfurl_links":   false,
  "unfurl_media":   false
}
```

**Three message variants from `Build Notification`:**

1. **Clean success** (no failures):
   `New jobs have been added to Airtable. (73)`

2. **Partial failure** (rate limits or other errors):
   `Airtable: 40 added, 57 rate-limited, 0 other failed (out of 97).`

3. **No new** (all duplicates):
   `No new jobs added.`

The `Has Notifications?` IF gate prevents firing variant 3 — if `count == 0` (zero successes), the workflow ends silently rather than spamming Slack with empty-run pings.

---

## 8. Guards

| Guard | Purpose | Storage |
|---|---|---|
| Run guard | 45 min minimum between runs of the same scope | `staticData.linkedinScraperLastStartMs_<scope>` |
| In-execution guard | Refuse to emit twice for same `$execution.id` | `staticData.splitLastExecutionId_<scope>` |
| Tuple dedup | Drop `(keywords, location, workType, datePosted, windowId)` repeats | per-execution Set |
| Budget window | 10 actor calls per scope per 15 min | `staticData.splitBudget_<scope>` |
| Hard query cap | 10, enforced both in Config and Apify HTTP body | inline `if (idx > 10) throw` |
| Apify serialization | 1 actor call at a time with 5 s gap | `options.batching.batch` on HTTP node |
| Airtable serialization | ≤ 4 req per 1.1 s = ~3.6 req/s, under the 5/s/base limit | `options.batching.batch` |
| Apify safety cap (script-side) | `if (idx > 10) throw` inside the HTTP body's expression | runtime exception |

All scope-keyed (`<scope>` = `role_engineer` / `role_architect_builder` / `role_leadership` / `role_executive`) so the four workflows don't block each other.

---

## 9. Scoring rules (verbatim from `Dedup and Score`)

Per-job `relevanceScore` is computed additively, clamped to `0..100`, with `isHighRelevance = score >= 60`.

| Component | Score |
|---|---:|
| Title exact match (any `titleKeywords`) | **+30** |
| Title partial match (any `partialKeywords`, only if no exact match) | **+15** |
| Senior title (`chief`, `vp`, `vice president`, `director`, `head of`, `cto`, `cio`, `caio`, `principal`, `staff`, `lead`) | **+5** |
| Remote (workplace or location) | **+20** |
| Hybrid (workplace or location, only if not Remote) | **+20** |
| NYC metro keyword (only if not Remote/Hybrid) | **+15** |
| Salary min ≥ $150K | **+10** |
| Salary max ≥ $150K (only if min didn't trigger) | **+5** |
| Mid-market company (100–2,000 employees) | **+10** |
| Large company (2K–10K, only if mid-market didn't trigger) | **+5** |
| AI governance / adoption keywords in description | **+10** |
| Junior / entry-level signals (`intern`, `junior`, `entry-level`, `associate`, `analyst`) | **−20** |
| Dual NY + London office (same company, retro pass) | **+15** |

`titleKeywords` and `partialKeywords` are role-specific and live in the `Config` node's `scoring` object. Other keyword arrays (`seniorityWords`, `nycAreaKeywords`, `aiGovernanceKeywords`, `londonKeywords`) are shared across all four workflows.

---

## 10. Known issues and resolutions

Full debug history. Each entry is a real bug we shipped through.

### 10.1 Single click → 28 actor calls

**Symptom:** One Execute Workflow click in the legacy workflow produced 28 actor runs in the Apify console, all with the same `_n8nExecutionId`.

**Wrong hypothesis:** Schedule trigger leak; n8n re-firing the workflow; hidden re-entry edge in the workflow graph.

**Real cause:** The `@apify/n8n-nodes-apify` v1 community node, in `Run actor and get dataset` mode, iterated its 10 input items in a self-cycling pattern — visiting each query 2–3× over a ~70 s cycle period.

**Fix:** Replaced the community node with `n8n-nodes-base.httpRequest` calling the Apify v2 sync endpoint directly. One call per input item. Determinism restored.

### 10.2 5 of 10 calls silently dropped

**Symptom:** First HTTP-based execution fired only 5 actor runs (qidx 1, 2, 3, 4, 6). qidx 5, 7, 8, 9, 10 missing. All 5 succeeded; no error in the n8n run.

**Wrong hypothesis:** Apify per-account concurrent-run cap of 5.

**Real cause:** `actor-memory-limit-exceeded` — 5 parallel actor runs at ~4 GB each consumed 20 GB of the 21,504 MB account ceiling, so the next 5 launches were rejected. The error came back as a 200 with body `{"error":{"type":"actor-memory-limit-exceeded",...}}`. With `neverError: true` set, n8n treated it as a normal response. `Flatten` then dropped it (not an array), and `Normalize` filtered it out (no `title`).

**Fix:** `options.batching.batch = { batchSize: 1, batchInterval: 5000 }` on the HTTP node — serializes the 10 calls. Memory usage stays at one 4 GB run at a time.

### 10.3 57 of 97 Airtable POSTs silently dropped

**Symptom:** Airtable showed 40 new records but Slack reported 40, n8n's Create Airtable Record output showed 97 items in / 97 items out, and n8n said "success."

**Wrong hypothesis:** Field validation rejecting some records.

**Real cause:** Airtable's per-base rate limit is **5 req/s**. n8n's HTTP node default-fires all input items in parallel. 57 of the 97 POSTs came back as `{"errors":[{"error":"RATE_LIMIT_REACHED",...}]}` — body looked fine, no record id present. `Build Notification`'s old code only counted `record[0].id` as success and silently treated the rest as duplicates.

**Fix (two parts):**
1. `options.batching.batch = { batchSize: 4, batchInterval: 1100 }` on both Airtable HTTP nodes — caps at ~3.6 req/s. Same fix on `Check Airtable Existing` since the dedup queries had the same risk.
2. Rewrote `Build Notification` to bucket responses into `succeeded / rateLimited / otherFailed / total` and surface all four to Slack.

### 10.4 Resume webhook crash

**Symptom:** Workflows that wrote new jobs but had none scoring ≥70 errored at `Trigger Resume Workflow` with "URL parameter must be a string, got undefined."

**Real cause:** `Queue Resume Generation` returned `[{ json: { triggered: 0 } }]` when no jobs qualified. That single item had no `webhookUrl`. Downstream HTTP node's URL expression evaluated against undefined.

**Fix:** `if (toGenerate.length === 0) return [];` — empty array short-circuits the chain.

### 10.5 JDs truncated

**Symptom:** Airtable records had only ~200-char snippets in `Full Description`.

**Real cause:** During the rate-limit debug we set `fetchFullDescription: false` to dodge LinkedIn 429s on the actor's per-job detail fetches. With it false, the actor only returned the search-results snippet.

**Fix:** Reverted to `fetchFullDescription: true`. Since actor calls are now serialized via batching (one at a time, 5 s apart), and the actor itself paces its detail fetches with `0.8–2.0 s` jitter, the LinkedIn rate-limit risk is bounded.

### 10.6 SplitInBatches Loop wrapper killed the chain

**Symptom:** First attempt at serialization wrapped the HTTP call in a `Loop Over Queries` (SplitInBatches v3) node. Workflows ran 10 actor calls successfully but stopped 19 s after the 10th call without firing Normalize/Dedup/Airtable.

**Real cause:** SplitInBatches v3's `done` output (index 0) is supposed to fire on a final 11th node invocation after all batches are processed. The back-edge from `Flatten Apify Dataset → Loop Over Queries` failed to trigger that 11th run — `Flatten` only ran 9 times despite HTTP running 10 times. Topology was fragile.

**Fix:** Removed the loop wrapper entirely. The HTTP node's own `options.batching` provides the same serialization without a loop topology. Single linear chain: `Split → HTTP (batched) → Flatten → Normalize → ...`.

---

## 11. Content angles (appendix)

Hooks worth pulling out of this spec for a LinkedIn / blog post about the system:

1. **"Single click, 28 actor calls"** — the false-loop diagnosis. Frames how community-node black boxes can quietly multiply your API spend, and how to verify with `_n8nExecutionId` grouping in the Apify console.

2. **"n8n's `Loop Over Items` killed my workflow. The fix was a single line of HTTP-node config."** — `options.batching.batch` on the HTTP Request node beats a SplitInBatches wrapper for serialization, both in robustness and topology simplicity.

3. **"Why I replaced an Apify SDK node with a bare HTTP Request"** — value prop for picking the standard HTTP node over a community SDK node when determinism matters more than ergonomics.

4. **"Two different rate limits, one root cause"** — Apify memory cap + Airtable 5/s/base both manifested as silent drops because `neverError: true` masked the response payloads. The lesson: always inspect the body, never trust the status code, and surface failure counts in your notification stage.

5. **"4 workflows, 1 engine"** — keyword-set sharding by role family (Engineer / Architect / Leadership / Executive), each with its own scope-keyed run guard, budget window, and dedup state, sharing identical pipeline nodes.

6. **"Score, dedup, write-once"** — the discipline that turns a noisy LinkedIn search into a tier-1 daily list. Source ID + Source compound key in Airtable enforces at-most-once ingest. Relevance scoring tags a `Tier` for downstream `build_packages.py` to pick up.

7. **"Make your scraper observable from outside the box"** — the actor input includes `_n8nExecutionId` and `_n8nWorkflowScope` so every Apify run can be traced back to which n8n execution and which scope drove it. This was the diagnostic that broke open issue 10.1.

---

## 12. Source-of-truth files

- Live workflow JSON: pull via `GET http://10.10.0.80:5679/api/v1/workflows/<id>`
- Disk mirrors: `workflow-role-{engineer,architect-builder,leadership,executive}-http.json` (in this directory)
- Apify actor source: `M:\Code\Agenius-AI-Labs\apify-actors\actors\linkedin-jobs-scraper\`
- Airtable canonical field map: `M:\Code\Agenius-AI-Labs\personal\job-hunt\pipeline\PIPELINE-SPEC.md` §Airtable
- Downstream pipeline (Phase 3 tier classifier + package builder): same `PIPELINE-SPEC.md`
- MongoDB migration plan (parked): `PIPELINE-SPEC.md` §Phase 4
