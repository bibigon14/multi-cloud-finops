# Narrative - why multi-cloud-finops exists

## The gap

SRE and FinOps are converging. Companies that used to split
"reliability" and "cost" between two orgs are discovering that the
same problem - a workload consuming more than it should - shows up
in both. A pod stuck in a retry loop burns error budget AND burns
money. A node pool that never scales down burns money AND makes
capacity planning lie. The right team to own the detection is SRE;
the right organ to detect it is the SRE playbook.

That playbook has three load-bearing patterns:

- **SLOs**: a quantitative target for what "working well" means.
- **Error budgets**: the inverse of an SLO. How much failure fits
  within the target before we have to stop and fix things.
- **Burn-rate alerts**: not "has the SLO been violated", but "at
  the current failure rate, will the SLO be violated by the end of
  the window". Fires before the damage is done.

Finance orgs own a direct equivalent: a monthly budget is a cost SLO.
A line item overrunning the budget is an error budget violation. But
the alert most FinOps shops ship is the AWS Budget email that fires at
80% of actual spend - a lagging indicator, equivalent to "the SLO has
been violated" rather than "it's about to be".

This repo closes that gap: cost observability built from SRE primitives.

## The cross-cloud angle

Any single-cloud FinOps tool is one acquisition or one regulatory
pivot away from being useless. Real production in 2026 spans at least
two providers, and the schemas are mutually hostile:

- GCP: `gcp_billing_export_v1_*` with nested `credits` arrays
- AWS: CUR 2.0, Parquet, dozens of columns, Athena partition projection
- OCI: usage reports as CSV in Object Storage
- Azure: Cost Management exports to Storage Account, different schema per export type

The FinOps Foundation spent 2024-2026 writing FOCUS 1.0 to unify
these. This repo is built on the assumption FOCUS wins - the primary
query path uses FOCUS tables when they exist, legacy per-cloud schemas
as fallback. In v0.2+ that means one SQL query runs against all four
clouds without a per-cloud conditional.

## What this proves on a resume

- Platform / Senior SRE mindset: owning cost as a first-class
  reliability signal, not delegating it to a finance dashboard.
- Multi-cloud literacy without the usual "we use all five clouds"
  resume inflation: real exports, real queries, real alerts, three
  measurable milestones away from v0.5 being feature-complete.
- Awareness of emerging standards (FOCUS 1.0) before they become
  table stakes - shows the person tracking industry direction, not
  only solving yesterday's problems.
- A direct, honest narrative: no rebranding of "we looked at the
  billing dashboard" as "we built FinOps capability".

## What this does NOT do

- Does not replace a full-featured FinOps SaaS like CloudHealth or
  Vantage. Those have deeper features (reserved-instance recommendations,
  commitment simulation, historical anomaly ML). Those features
  cost money and are overkill at single-engineer scale.
- Does not do showback / chargeback on its own. v0.4 adds the
  attribution data; the showback presentation layer is a different
  project.
- Does not forecast revenue-proportional cost. That needs application
  metrics joined to billing, which is a v1.0 feature.
