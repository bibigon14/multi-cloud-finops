# 2026-11-09 Cloudflare Workers KV free tier exhausted (sre-portfolio)

**Author**: Dmitry Stepanov
**Severity**: SEV-3 (user-visible counter stale, no revenue impact)
**Duration**: ~13.5 hours (10:30 PT 2026-11-09 to 00:00 UTC 2026-11-10)
**Detected by**: `cf-usage` shell function, first run against live Cloudflare
account, 24 minutes after shipping this repo's v0.1. Cloudflare's own 90%
warning email landed earlier (09:32 PT) but in a general-purpose inbox
where no one was watching; the hard-quota 429s started at 10:25 PT.

## Summary

The `sre-portfolio` Cloudflare Worker's visitor-tracking path exhausted
the 1,000-put-per-day Workers KV free-tier limit at approximately
10:30 PT on 2026-11-09, after ~7 hours of normal traffic. The KV put
API returned HTTP 429 for the remainder of the UTC day. Visitor
counters silently stopped incrementing until the 00:00 UTC reset the
following day. Static content, analytics reads, and the CI matrix
widget continued to serve normally because none of those paths write
to KV at steady state.

No one was paged; the counter is a soft dependency and the incident
was caught by a tool shipped the same morning rather than by user
report.

## Timeline

All times PT (UTC-08) unless noted.

| Time | Event |
|---|---|
| 09:32 | Cloudflare notification email delivered to `dstepanov77@icloud.com`: *"KV daily operation limit 90% reached"*. Landed in a general-purpose inbox, went unread for ~3 hours - the alert existed, but nobody was watching the channel it arrived on. |
| 10:06 | `multi-cloud-finops` v0.1 shipped; repo scaffold pushed to GitHub |
| 10:17 | `sre-portfolio` Worker redeployed with the new `multi-cloud-finops` project card and updated `CI_REPOS` / `WATCHED_REPOS` constants |
| 10:25 | Cloudflare notification email delivered: *"KV daily operation limit exceeded"* - hard quota hit, puts now return 429 |
| 10:30 | First-ever `cf-usage` run against the live Cloudflare account; GraphQL Analytics reported `sre-portfolio: req=12912 err=0 subreq=13974` and `purrmeowca: req=5905 err=0 subreq=4888` over the last 24h window |
| 10:38 | 90%-and-exceeded emails read for the first time; root cause investigation starts |
| 10:40 | Root cause localized in `worker.js:trackVisit()` - per-request KV writes with an in-memory 60-second dedup cache |
| ~11:00 | Fix deployed: `DEDUPE_WINDOW_MS` bumped from 60s to 1h; in-memory cache capacity raised from 1,000 entries to 10,000 so hot entries survive more cold starts (`sre-worker` commit `adc8490`) |
| 00:00 UTC (16:00 PT) | KV put quota reset by Cloudflare; visitor tracking resumes |

## Root cause

`trackVisit()` writes one JSON record per unique (IP, request-type) pair
per minute to the `VISITS` KV namespace. The dedup check lives in a
per-Worker-instance `Map`:

```javascript
const _visitCache = new Map();
const DEDUPE_WINDOW_MS = 60 * 1000;

function shouldSkipWrite(ip, requestType) {
  const cacheKey = `${ip}:${requestType}`;
  const last = _visitCache.get(cacheKey);
  const now = Date.now();
  if (last && (now - last) < DEDUPE_WINDOW_MS) return true;
  _visitCache.set(cacheKey, now);
  if (_visitCache.size > 1000) { /* LRU trim */ }
  return false;
}
```

Two assumptions in that design didn't hold at this traffic volume:

1. **Horizontal scale**. Cloudflare Workers runs one isolate per data
   center. A visitor whose requests are routed across several Points of
   Presence (not uncommon for CDN-fronted static sites and scanners)
   will hit a cache miss at each PoP and trigger one write per PoP.
2. **Cold starts**. `_visitCache` lives in V8 isolate memory. Isolates
   are evicted during idle periods; the next request on that PoP starts
   with an empty cache and writes again. At the 12.9k req/24h observed
   volume, idle gaps between bursts are large enough for isolate
   recycling.

Effective dedup ratio ended up closer to 5-8x rather than the ~60x the
asset-waterfall comment in the code assumed. 12.9k requests * 1/5 to
1/8 effective dedup = 1,600 - 2,600 puts/day, well above the 1,000
free-tier ceiling.

The design was sound for the traffic the site had when the code was
written. The design did not scale as the CI matrix widget's own
5-minute polls, the live GitHub ticker, and organic visitor growth
pushed the request rate past 10k/day.

## Resolution

Short-term (deployed at ~11:00 PT, commit `adc8490`):

- `DEDUPE_WINDOW_MS`: 60s → 1h (60x reduction in effective write rate
  per visitor)
- Dedup cache capacity: 1,000 → 10,000 entries (makes hot entries much
  more likely to survive isolate cold starts)

Projected new put rate at identical request volume: 100 - 200
puts/day, which fits in the free tier with a 5x safety margin.

## Why neither the Console budget alert nor a traditional cost-monitor
would have fired

Cloudflare does not bill per-KV-put over free tier - the limit is a
hard quota. Once exceeded, puts return 429 for the rest of the day,
no dollar charge accrues. A budget alert keyed on month-to-date spend
would read $0.00 during the entire incident. The thing you want to
measure here is *approach to a quota ceiling*, not *dollars spent*,
and that needs a dedicated signal, which neither the CF dashboard
Billing page nor an AWS-Budgets-style tool expose by default.

This is exactly the gap this project exists to cover. The `cf-usage`
function pulls the live operations count from the GraphQL Analytics
API; a dashboard panel plotting `put_ops / 1000` as "fraction of
free-tier budget consumed today" would have alerted at >= 80% around
08:00 PT, roughly 2.5 hours before the quota actually blew.

## Lessons

1. **Quota ceilings are reliability signals**. Treat an approach to a
   quota the same way SRE practice treats an approach to an error
   budget: multi-window multi-burn-rate, with a fast-window (1h) and
   a slow-window (6h) alert. The SRE Workbook math works unchanged;
   only the numerator changes.
2. **"Free tier" is not "unlimited"**. Services that do not charge
   over free tier (Cloudflare Workers KV, Cloudflare R2 Class A ops,
   GCS Early Delete) instead hard-block, which is a worse failure
   mode than a surprise bill because it skips every traditional cost
   control that keys on dollars.
3. **Provider-side warnings are only as good as the channel they land
   on**. Cloudflare's own 90% warning fired at 09:32 PT, well before
   the quota wall, but it arrived as an email in a mixed inbox with
   promotions and newsletters. The signal existed; the attention path
   did not. A dashboard panel next to the rest of the infra would
   have made the same signal visible in the context people actually
   look at - the classic SRE argument for owning your own observability
   layer instead of trusting vendor emails to reach the right human in
   time.
4. **Validation that the project paid for itself in 24 minutes**.
   `multi-cloud-finops` v0.1 was shipped at 10:06 PT. The `cf-usage`
   function it includes was first run at 10:30 PT. The incident it
   surfaced was observable in that same output, 8 minutes before
   Cloudflare's own notification email arrived. The project did its
   job on day zero against a real event, not a synthetic one.

## Follow-ups

- [ ] Add a quota-based burn-rate panel to the FinOps Grafana
      dashboard (v0.2 work): `put_ops_today / daily_quota` as a
      stat with yellow at 0.7 and red at 0.9.
- [ ] Add a Cloudflare GraphQL datasource provisioning file next to
      the BigQuery one in `grafana/datasources/`.
- [ ] Evaluate whether `sre-portfolio`'s visitor tracking should move
      from Workers KV to Cloudflare Analytics Engine (25M writes/day
      free, built for append-only time-series counters). KV is the
      wrong primitive for a per-request counter; this incident is the
      excuse to migrate.
- [ ] Alternative: move to Workers Paid plan ($5/month flat, 1M KV
      puts/day). Document the break-even analysis in the migration
      decision record.

## Appendix: the output that surfaced the incident

```
❯ cf-usage
--- Cloudflare account: My Account (4df5c0c98d64558858be99df4dbbf152) ---
--- Zones ---
  dstepanov.dev   plan:Free Website   status:active
  purrmeowca.com   plan:Free Website   status:active
--- Workers scripts ---
  purrmeowca   last-modified:2026-09-17T17:31:41.748064Z
  sre-portfolio   last-modified:2026-11-09T18:17:32.043523Z
--- Workers last 24h (GraphQL Analytics) ---
  sre-portfolio   req:12912  err:0  subreq:13974
  purrmeowca   req:5905  err:0  subreq:4888
```

Eight minutes later, the Cloudflare notification email landed. The
GraphQL request count was the first visible signal that put-rate had
left the free-tier envelope; the email was a confirmation.
