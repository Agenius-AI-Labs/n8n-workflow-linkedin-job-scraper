# LinkedIn Job Scraper Workflows (Role-Split)

> **Current canonical spec:** [`WORKFLOW-SPEC.md`](WORKFLOW-SPEC.md). The notes below describe the earlier 2-workflow version using the `@apify/n8n-nodes-apify` community node; the production system is now 4 workflows (Engineer / Architect-Builder / Leadership / Executive) using `httpRequest` directly.


Two separate workflows split by role family:

- `workflow-role-executive.json`
  - Focus: executive leadership roles
  - Examples: Chief, VP, Head, Director AI/Automation
- `workflow-role-engineer.json`
  - Focus: engineer/developer/architect roles
  - Examples: AI automation engineers, RPA/power platform/integration developers, automation architects

`workflow.json` currently mirrors `workflow-role-executive.json` as default.

## Search Scope in each workflow
Both workflows include:

- NYC metro: remote + hybrid
- United States: remote only

## Safe Mode (kept in Config)
- `safeMode: true`
- `safeMaxQueries: 2`
- `safeMaxResults: 10`
- `safeFetchFullDescription: false`

## Date window
- Default: `past_24h`
- Optional compare: `includeComparisonWindow: true` + `comparisonDatePosted: 'past_week'`
