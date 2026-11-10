# 0001 - Move visitor tracking from Workers KV to Analytics Engine

* Status: Accepted
* Date: 2026-11-09
* Deciders: Dmitry Stepanov
* Technical Story: [day-zero incident post-mortem](../incidents/2026-11-09-cf-kv-free-tier-exhausted.md)

## Context and Problem Statement

The `sre-portfolio` Cloudflare Worker tracks visitors to sre.dstepanov.dev
by writing one JSON record per unique (IP, request-type) pair to the
`VISITS` Workers KV namespace, with an in-memory 60-second dedup cache.

On 2026-11-09 the Worker exceeded the Workers KV free-tier quota of
1,000 put operations per day. KV writes returned HTTP 429 for the
remainder of the UTC day; visitor counters silently stopped
incrementing until the 00:00 UTC reset. Root cause (detailed in the
post-mortem) is that the per-instance dedup cache does not scale across
horizontal Worker isolates or survive cold starts, so the effective
dedup ratio at ~12k requests/day is 5-8x rather than the assumed 60x.

The short-term fix (`DEDUPE_WINDOW_MS` 60s → 1h, cache capacity 1k →
10k) brings estimated KV puts down to ~100-200 per day with a 5x safety
margin. That addresses the immediate outage but leaves the fundamental
architectural issue: Workers KV is the wrong primitive for a
per-request time-series counter, and traffic growth will exhaust the
quota again at a higher rate.

## Decision Drivers

* No new recurring dollar cost. A move to Workers Paid at $5/month
  would solve the quota problem immediately but changes the project's
  economics from free-tier-infrastructure-portfolio to
  paid-tier-infrastructure-portfolio, a conversation about cost
  trade-offs the repo already opens.
* Narrative value. A deliberate migration from the wrong primitive to
  the right one after a real production incident is a stronger
  portfolio data point than a plan-upgrade purchase.
* Read-path flexibility. KV stores one aggregated blob per IP keyed on
  IP, which means the `/stats` endpoint can only answer questions
  structured around that single key. Analytics Engine stores raw
  events with up to 20 string dimensions and a time axis, and queries
  through a GraphQL API with SQL-like aggregation. "Which country sent
  the most scanner requests this week?" or "What was the hit rate on
  /multi-cloud-finops in the first 24 hours?" are unanswerable from KV
  without pre-aggregation, and trivially answerable from AE.
* Migration safety. The system has to keep collecting visitor data
  throughout the migration; reverting to the KV path has to remain
  possible for the first ~30 days.

## Considered Options

### A. Upgrade to Workers Paid plan

$5/month flat, 1,000,000 KV puts/day, no further refactoring. Code
stays identical to today.

* Pros: zero refactoring risk; the quota problem disappears
  immediately; same read path.
* Cons: changes the project's cost posture from $0 to $5/month, which
  the portfolio audience will notice; does not address that KV is
  still the wrong primitive for this workload; a future increase in
  traffic by 1000x hits the same ceiling in the same way.

### B. Migrate writes to Cloudflare Analytics Engine

Keep KV for cache-like use (GitHub events cache, CI status cache,
dedup checkpoint). Move visitor-event writes to a new
`sre_portfolio_visits` Analytics Engine dataset. Rewrite `/stats`
endpoint to query AE through the Cloudflare GraphQL Analytics API.

* Pros: AE is purpose-built for append-only time-series counters at
  Workers edge, with 25M writes/day free; read path becomes
  strictly more powerful (arbitrary dimension aggregation); zero
  recurring cost; a clean portfolio narrative ("learned the primitive
  was wrong from a real incident, migrated").
* Cons: write path and read path both change; stats endpoint has to
  fetch over GraphQL inside the Worker, which needs an API token
  stored as a Worker secret; AE stores raw events, so query cost
  scales with window size.

### C. Durable Object counter per IP

Move each per-IP record into a DO instance. DO storage has its own
quotas.

* Pros: strong consistency per IP.
* Cons: DO is for strongly-consistent per-entity state (shopping
  carts, game sessions), not for a write-once-per-event ticker; DO
  storage is still metered and would substitute one quota problem
  for another; adds significant complexity.

## Decision Outcome

Chosen option: **B. Migrate writes to Cloudflare Analytics Engine.**

Analytics Engine is the correct primitive for this workload, offers
strictly more query power than the KV blob-per-IP layout, and keeps
the project's $0 recurring cost. The migration is staged to preserve
safety:

* **Phase 1 (this change)**: dual-write. `trackVisit()` keeps the
  existing KV put (now with 1h dedup, safe under quota) and in
  parallel calls `env.ANALYTICS.writeDataPoint(...)` with the same
  event. `/stats` endpoint keeps reading from KV. If AE writes are
  wrong or the data model is off, nothing user-visible breaks.
* **Phase 2 (~30 days later, once AE has useful history)**: rewrite
  `loadVisitors(env, dateKey)` to issue a GraphQL query against
  the `sre_portfolio_visits` dataset over `dateKey`'s UTC day,
  aggregate per IP, and return the same shape the current KV reader
  returns. Add a `CF_GRAPHQL_TOKEN` Worker secret with the account's
  Analytics:Read scope. Switch `/stats` to the new path.
* **Phase 3**: drop the KV put from `trackVisit()`. Keep the KV
  namespace itself because the `GH_CACHE_KEY`, `GH_CONTRIB_CACHE_KEY`,
  `GH_CI_CACHE_KEY` and the dedup checkpoint all still use it, at
  much lower rates than visitor tracking did.

## Positive Consequences

* Resolves the incident class permanently: AE free-tier ceiling is
  25M writes/day, which at current rates would not be hit for over
  5 years of traffic growth.
* Enables questions the KV layout couldn't answer without pre-aggregation:
  per-country/per-path/per-ISP top-N, time-of-day distribution, 90th
  percentile referrer counts.
* Serves as a worked example in the `multi-cloud-finops` repo for
  "right primitive after real-world quota incident", a pattern that
  recurs across GCS lifecycle rules, Lambda concurrency, and DynamoDB
  provisioned throughput.

## Negative Consequences

* Read path requires an HTTP fetch from inside the Worker (to the
  GraphQL API). Latency on `/stats` goes up from "KV read" to
  "outbound HTTPS". Acceptable because `/stats` is a Telegram command
  invoked a few times per day, not a user-facing hot path.
* Needs an API token stored as a Worker secret. The token has
  Account:Analytics:Read scope only; blast radius is read-only
  analytics data of the author's own Cloudflare account.
* Phase 2 adds a dependency on GraphQL schema stability. Cloudflare
  does occasionally rename dataset-adaptive-groups; the migration
  code has to be defensive.

## Links

* Incident post-mortem:
  [docs/incidents/2026-11-09-cf-kv-free-tier-exhausted.md](../incidents/2026-11-09-cf-kv-free-tier-exhausted.md)
* Cloudflare Analytics Engine docs:
  https://developers.cloudflare.com/analytics/analytics-engine/
* Workers KV limits:
  https://developers.cloudflare.com/workers/platform/limits/#kv-limits
