# Incident: GKE Cost Allocation feature did not populate goog-k8s-namespace labels

**Date observed:** 2026-11-14 to 2026-11-16
**Severity:** Low (portfolio completeness; no availability or data impact)
**Detected by:** v0.5 namespace panel showing "No data" after cluster teardown;
                 BigQuery direct inspection of Detailed billing export
**Author:** Dmitry Stepanov

## Summary

A dedicated GKE cluster `finops-demo-ns-capture` was spun up in us-central1-a
on 2026-11-14 10:03 PT specifically to let GKE Cost Allocation's backfill
pipeline populate the `goog-k8s-namespace` system label on the Detailed
BigQuery billing export, so the v0.5 Kubernetes namespace attribution panel
would show real GCP numbers alongside the AWS SCAD and Azure RG rows that
already worked. After 48+ hours of uptime with three workloads running in
three namespaces, the `system_labels` array on every `Kubernetes Engine`
row of the Detailed export remained empty. The feature did not populate as
GCP docs promise.

## Timeline

| When (PT) | Event |
|-----------|-------|
| 2026-11-12 09:03 | Original finops-demo cluster activated `--enable-cost-allocation` |
| 2026-11-12 15:12 | Original cluster torn down, ~6h feature window closed with 0 labels in export |
| 2026-11-14 10:03 | `finops-demo-ns-capture` cluster created (zonal, 1 preemptible e2-small, K8s 1.36.4 Standard Support) |
| 2026-11-14 10:04 | Three Pod kind manifests applied: nginx-default, busybox-data, nginx-platform |
| 2026-11-15 10:11 | 24h check: BQ shows 0 `system_labels` rows; only 2 GKE rows for 2026-11-14 (preemptible node had died and Pod kind manifests did not reconcile) |
| 2026-11-15 10:15 | Pod kind replaced with Deployments (auto-reconcile on node eviction); pods back to Running |
| 2026-11-16 09:13 | 48h+ total, 22h Deployments steady: BQ still shows **0 `system_labels` rows** for every one of 2026-11-12..2026-11-16 |
| 2026-11-16 09:14 | Decision: teardown, accept honest limitation on the GCP namespace panel |

## Pod Running proof

```
default         deployment.apps/nginx-default    1/1   22h
team-data       deployment.apps/busybox-data     1/1   22h
team-platform   deployment.apps/nginx-platform   1/1   22h
```

## BQ proof (system_labels never appeared)

```
+------------+-----------+-------------------------+---------------------+------------+
|    day     | row_count | rows_with_system_labels | rows_with_namespace | total_cost |
+------------+-----------+-------------------------+---------------------+------------+
| 2026-11-16 |        20 |                       0 |                   0 |     1.3063 |
| 2026-11-15 |        36 |                       0 |                   0 |     2.3937 |
| 2026-11-14 |         2 |                       0 |                   0 |     0.1041 |
| 2026-11-13 |        85 |                       0 |                   0 |     0.7433 |
| 2026-11-12 |       278 |                       0 |                   0 |     3.1986 |
+------------+-----------+-------------------------+---------------------+------------+
```

## Root cause (hypothesis)

Not conclusively known; GCP provides no observability into the Cost
Allocation processing pipeline. Working theories, ranked by likelihood:

1. **Billing account tier / project-level opt-in not reflected in the
   `--enable-cost-allocation` CLI flag alone.** The feature may require
   an explicit account-scope flag or support ticket on top of the
   cluster-scope flag, and silently no-ops otherwise.
2. **Cost Allocation agent may need steady-state operation window
   longer than our tests.** 48h of uptime with preemptible evictions
   interleaved may still have been insufficient for the metering pipeline
   to batch-write labels to the billing export.
3. **GKE Standard zonal + preemptible single-node topology** may not be a
   supported combination for Cost Allocation; docs do not forbid it, but
   silent no-op is consistent with that.

The first incident (2026-11-12) was explained as "6h window too narrow."
The second incident rules that explanation out: a 48h window with correct
Deployment reconciliation also produced 0 labels. The feature as
documented does not describe our observed behaviour.

## Impact

- v0.5 GCP namespace panel permanently shows a honest-limitation noValue
  notice instead of populated bars
- `$1.4` total AWS + GCP compute spend across both capture attempts
  (first 6h cluster + second 48h cluster)
- No data loss, no availability impact
- No impact to AWS SCAD panel or Azure RG panel on the same row - both
  continue to show real data as before

## What would have changed the outcome (and did not)

- Longer uptime window (48h vs 6h): no effect
- Deployment manifests instead of Pod kind (fixing preemptible eviction
  gap): no effect
- Explicit K8s version pin to current Standard Support (1.36.4): no
  effect
- Pods in multiple distinct namespaces (3) with sustained running CPU
  usage: no effect

## Fix

Accept the limitation and update the panel's `noValue` text from the
"first-time backfill up to 48h" placeholder we shipped in v0.5 to the
final explanation:

```
GKE Cost Allocation was enabled on finops-demo (2026-11-12) and
finops-demo-ns-capture (2026-11-14..16). Across both attempts, totalling
~54h of cluster runtime, Cost Allocation never populated
goog-k8s-namespace system_labels in the Detailed billing export. GCP
docs promise "up to 48h backfill" but did not deliver in this account
setup. The AWS SCAD and Azure ResourceGroupName fallback panels on this
row continue to work. Repro / debug data lives in
docs/incidents/2026-11-14-gke-cost-allocation-labels-did-not-populate.md.
```

## Follow-up

- [x] 2026-11-16: teardown `finops-demo-ns-capture`
- [x] 2026-11-16: incident filed (this document)
- [ ] 2026-11-16: update GCP namespace panel `noValue` text; commit as
      v0.5.1 README note
- [ ] If at some point GCP support confirms what the actual pre-condition
      is for Cost Allocation to populate, revisit; otherwise this stays
      an honest documented limitation in the portfolio

## Lessons

**"Up to 48h" from a cloud vendor is a ceiling, not a guarantee.**
Two attempts at ~24h and ~48h windows both returned nothing. For
anything time-sensitive (an interview demo, a stakeholder review),
budget 3x the vendor's quoted window or ship the honest-limitation
alternative inline from day one and promote it later if data arrives.

**Pod kind under preemptible nodes is a reconciliation trap.** The first
attempt wasted ~22h of its window because preemptible evictions deleted
Pods that no controller owned. Deployments / StatefulSets / Jobs are not
just an aesthetic preference here; they are the reason `kubectl apply`
semantics mean anything after the first node reboot. Documented in this
incident so the next demo cluster does not repeat it.

**Public-facing cost-observability projects benefit from documenting
negative results too.** The GCP namespace panel showing a readable
explanation of a GCP feature that did not work is itself a FinOps story -
observability projects regularly have to explain "why doesn't the vendor
tell us X", and the v0.5 panel now does.
