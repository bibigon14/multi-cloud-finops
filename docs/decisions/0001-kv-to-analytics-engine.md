# 0001 - Move visitor tracking from Workers KV to Analytics Engine

* Status: Accepted
* Date: 2026-11-09
* Revised: 2026-11-09 - initial free-tier assessment was incomplete; see below.
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

## Revision note: free-tier assessment was incomplete

The first draft of this record (committed 2026-11-09 at 17:28 PT)
argued that migrating to Analytics Engine would keep the project's
$0 recurring cost. That assertion was wrong.

The first deploy attempt that evening failed with Cloudflare API error
10089 ("You need to enable Analytics Engine"). Reading the dashboard
revealed that Analytics Engine is gated behind the Workers Paid plan
in 2026 pricing. The Analytics Engine dataset is free to create, but
writing to it from a Worker requires the account to be on Workers Paid
($5/month minimum).

This record was revised the same evening to reflect the actual trade-off.
The decision does not change - Analytics Engine is still the right
primitive for a per-request counter - but the honest framing is that
this is a **$5/month architectural decision**, not a free one. The
rest of the record carries that framing.

## Decision Drivers

* **Right primitive** - a per-request counter workload belongs in an
  append-only time-series store built for high-volume writes, not in
  a KV store that sorts documents by a single partition key. Workers
  Paid moves KV's own limit from 1k to 1M puts/day, but that just buys
  3 orders of magnitude of room in the wrong primitive.
* **Query power** - KV stores one blob per IP. Questions beyond "how
  many hits did this IP make" require pre-aggregation at write time,
  which is why the current `trackVisit` code is 70 lines of in-place
  state mutation. AE stores raw events with up to 20 string dimensions
  and a time axis; the same `/stats` numbers are a single aggregation
  query, and new questions ("which country sent the most scanner
  requests this week") are new queries, not new write paths.
* **Blast radius of growth** - at today's 12k req/day the KV-with-1h-
  dedup fix is safe. At 10x traffic (plausible if a single post picks
  up on Hacker News) the dedup ratio stays what it is, and the KV
  write rate scales linearly with traffic until it hits the next
  ceiling. AE's ceiling is 25M writes/day free; traffic would have
  to grow 1,000x before that becomes a concern.
* **Cost** - Workers Paid is $5/month flat. The decision is whether
  $60/year is worth the above three. For a portfolio project whose
  purpose is to demonstrate SRE judgment, choosing the right primitive
  on a real production workload is the demonstration; refusing to
  spend $5/month to make that choice available would itself be a
  signal in the wrong direction.

## Considered Options

### A. Upgrade to Workers Paid plan, keep KV write path as-is

$5/month, 1,000,000 KV puts/day. Code stays identical to today.

* Pros: zero refactoring risk; the quota problem disappears immediately.
* Cons: pays $5/month for 1000x more quota on the **wrong primitive**;
  future-me is still writing time-series counters into a document
  store keyed on IP; a 1000x traffic growth hits the next ceiling in
  exactly the same way; nothing is learned.

### B. Upgrade to Workers Paid plan and migrate writes to Analytics Engine

$5/month, same as option A, but the Worker writes events into a new
`sre_portfolio_visits` AE dataset instead of (or in addition to) KV.
`/stats` eventually reads from AE via the GraphQL Analytics API.

* Pros: $5 unlocks **both** the KV safety margin AND the correct
  primitive for the actual workload; strictly more query power than
  the KV blob-per-IP layout; the $5/month is the cost to make the
  right architectural choice visible, not the cost of a workaround.
* Cons: write and read paths both change; stats endpoint has to fetch
  over GraphQL inside the Worker, needing an API token stored as a
  Worker secret; a legitimate cost line that would not exist on
  option C.

### C. Revert and stay on KV with the 1h dedup patch

Keep the current shipped fix (`DEDUPE_WINDOW_MS` 60s → 1h). No further
architectural change. Status quo of this evening's short-term patch.

* Pros: zero recurring cost; code already deployed and verified.
* Cons: still the wrong primitive, now with a 60x fudge factor in
  front of it; next traffic growth cycle reopens the same ticket;
  no portfolio story beyond the 2026-11-09 incident post-mortem.

### D. Durable Object counter per IP

Move each per-IP record into a DO instance. DO storage has its own
quotas.

* Pros: strong consistency per IP.
* Cons: DO is for strongly-consistent per-entity state (shopping
  carts, game sessions), not for a write-once-per-event ticker; DO
  storage is still metered and would substitute one quota problem for
  another; adds significant complexity.

## Decision Outcome

Chosen option: **B. Upgrade to Workers Paid and migrate writes to
Analytics Engine.**

Option A buys quota headroom without fixing the architectural issue.
Option C defers the question to the next traffic growth cycle. Option
D substitutes a different quota.

Option B is the only option that spends the $5/month deliberately -
to unlock the correct primitive and to document that trade-off
explicitly. The $5/month is itself a portfolio signal: an engineer
who will not upgrade a personal project to the right architecture
is an engineer who will do the same thing at work.

Migration is staged for safety:

* **Phase 1 (this change)**: dual-write. `trackVisit()` keeps the
  existing KV put (now with 1h dedup) AND also calls
  `env.ANALYTICS.writeDataPoint(...)`. `/stats` endpoint keeps reading
  from KV. If AE writes are wrong or the data model is off, nothing
  user-visible breaks. The KV path is a fallback for ~30 days.
* **Phase 2 (~30 days later, once AE has useful history)**: rewrite
  `loadVisitors(env, dateKey)` to issue a GraphQL query against the
  `sre_portfolio_visits` dataset, aggregate per IP, and return the
  same shape the current KV reader returns. Add a `CF_GRAPHQL_TOKEN`
  Worker secret with Account:Analytics:Read scope. Switch `/stats`
  to the new path. Validate output matches the KV-backed version
  within rounding before removing the KV read.
* **Phase 3**: drop the KV put from `trackVisit()`. Keep the KV
  namespace itself because `GH_CACHE_KEY`, `GH_CONTRIB_CACHE_KEY`,
  `GH_CI_CACHE_KEY` and the dedup checkpoint all still use it, at
  put rates that stay inside even the free-tier ceiling.

## Positive Consequences

* Resolves the incident class permanently. AE free-tier ceiling (now
  accessible on Workers Paid) is 25M writes/day; at current rates
  that is over 5 years of linear traffic growth.
* Enables queries the KV layout couldn't answer without pre-aggregation:
  per-country / per-path / per-ISP top-N, time-of-day distribution,
   90th-percentile referrer counts. `/stats` becomes a GraphQL query,
  not a KV iteration.
* Simplifies `trackVisit` from a 70-line read-modify-write cycle with
  per-day aggregation and retention cleanup into a single
  `writeDataPoint` call plus owner skip and in-memory dedup.
* Serves as a worked example in the `multi-cloud-finops` repo for
  "right primitive after real-world quota incident, including the
  cost delta", a pattern that recurs across GCS lifecycle rules,
  Lambda concurrency, and DynamoDB provisioned throughput.

## Negative Consequences

* **New $5/month recurring cost.** First recurring cost on any
  Cloudflare resource in this portfolio. The cost is documented and
  deliberate; it is not a workaround expense. Break-even against the
  engineering cost of debugging the next free-tier incident is
  "roughly one more incident of similar scope".
* Read path requires an HTTP fetch from inside the Worker (to the
  GraphQL API). Latency on `/stats` goes up from "KV read" to
  "outbound HTTPS". Acceptable because `/stats` is a Telegram command
  invoked a few times per day, not a user-facing hot path.
* Needs an API token stored as a Worker secret. The token has
  Account:Analytics:Read scope only; blast radius is read-only
  analytics data of the author's own Cloudflare account.
* Phase 2 adds a dependency on the Cloudflare GraphQL schema. CF
  does occasionally rename dataset-adaptive-groups; the migration
  code has to be defensive and the query shape is explicitly fixed
  in `queries/cf-analytics-engine/visitors-per-day.graphql`.

## Links

* Incident post-mortem:
  [docs/incidents/2026-11-09-cf-kv-free-tier-exhausted.md](../incidents/2026-11-09-cf-kv-free-tier-exhausted.md)
* Cloudflare Workers pricing (Workers Paid section):
  https://developers.cloudflare.com/workers/platform/pricing/
* Cloudflare Analytics Engine docs:
  https://developers.cloudflare.com/analytics/analytics-engine/
* Workers KV limits (what we hit):
  https://developers.cloudflare.com/workers/platform/limits/#kv-limits
