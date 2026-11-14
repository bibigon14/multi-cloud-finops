# Runbook: CostAnomaly_GCP / CostAnomaly_AWS

**Alert:** `CostAnomaly_GCP` or `CostAnomaly_AWS`
**Severity:** warning (not page; investigate during business hours unless it keeps firing)
**Fired by:** `grafana/alerts/cost-anomaly.yaml`
**Query:** `queries/anomaly-zscore.sql` / `queries/aws-anomaly-zscore.sql`

## What it means

One or more cloud services spent more than 3 standard deviations above
their own 7-day rolling baseline yesterday. The noise floor is `$0.05/day`
baseline mean; a minimum of 5 of the 7 preceding days must have data.
This is designed to catch:

- A resource provisioned yesterday that was not meant to stay up
  (forgotten GKE/EKS node pool, a demo cluster that skipped its
  teardown)
- A retention policy change that silently started growing a storage
  bucket
- An uncapped API consumer that only writes meaningful traffic from
  one specific day onwards
- A pricing-tier change on the vendor side (e.g. Extended Support
  penalty on a Kubernetes version crossing lifecycle boundary)

What it is **not** designed to catch:

- Steady-state growth below 3σ (use the burn-rate alert for that)
- The first N days of a brand-new service (status `insufficient-history`
  suppresses these)
- Cent-level daily movement on a tiny service (status
  `below-noise-floor` suppresses these)

## First 5 minutes

Open the dashboard row "Cost anomaly detection (z-score)" at
`https://grafana.homelab.local/d/mcf-gcp-mtd/multi-cloud-cost-mtd-2b-burn-rate`.

Look for `critical` rows in the last day. Each row is
`(day, service, cost_usd, baseline_mean, z_score)`. The z-score tells
you how far above the baseline the spend is - z=6 is six times the
baseline standard deviation, z=20 is extreme.

## Diagnosis - follow the service

For the service showing the highest z-score:

**GCP**:

```bash
# Top resources for that service in the last day
bq query --use_legacy_sql=false --format=pretty <<SQL
SELECT
  resource.name AS resource_name,
  ROUND(SUM(cost), 4) AS cost_usd
FROM \`dstepanov-gke-platform.billing_export.gcp_billing_export_resource_v1_0108CD_97A262_B94181\`
WHERE DATE(_PARTITIONTIME) = CURRENT_DATE() - 1
  AND service.description = '<service name>'
GROUP BY 1
ORDER BY 2 DESC
LIMIT 10
SQL
```

**AWS**:

```bash
# Top resources - use Athena CUR query against resource_id or line_item_resource_id
aws athena start-query-execution \
  --query-string "SELECT line_item_resource_id, ROUND(SUM(line_item_unblended_cost), 4) AS cost_usd FROM multi_cloud_finops.data WHERE date_trunc('day', line_item_usage_start_date) = current_date - interval '1' day AND product_servicecode = '<service>' GROUP BY 1 ORDER BY 2 DESC LIMIT 10" \
  --result-configuration OutputLocation=s3://<athena-results-bucket>/
```

The resource names/IDs tell you what to kill or investigate.

## Common causes and fixes

| Cause | Signal | Fix |
|-------|--------|-----|
| Demo cluster that skipped teardown | New cluster name, EC2/GKE compute spike | `scripts/billing-audit.sh` to confirm, teardown normally |
| EKS Extended Support penalty | AmazonEKS exactly 6x baseline | See `docs/incidents/2026-11-12-eks-extended-support-penalty.md`; pin cluster to current Standard-Support version |
| CloudWatch Logs retention change | AmazonCloudWatch slow climb | Audit log groups' `--retention-in-days`, set reasonable defaults |
| Storage bucket unbounded growth | Cloud Storage / S3 climbing linearly | Lifecycle rule for old objects |
| NAT Gateway traffic spike | AmazonVPC jumped | NAT flow logs, usually a chatty pod or cross-AZ data transfer |
| Vendor pricing change | All resources in service jumped on the same day | Nothing you did; document and either accept or migrate |

## Resolve the alert

The alert auto-resolves once the service drops back below 3σ for one
query cycle. If the root cause is an accepted change (e.g. real workload
growth), either:

1. Let the baseline catch up over the next 7 days - the window will
   shift and the new level becomes the baseline
2. Tune the service out of the alert if it will be persistently noisy
   (add a service-name filter to `cost-anomaly.yaml`)

If the root cause is a mistake (forgotten teardown, misconfiguration),
fix and file a short incident note in `docs/incidents/`. Pattern:
`YYYY-MM-DD-<slug>.md`, same shape as the existing entries.

## Why 3σ, not 2σ

A 2σ threshold would fire on ~5% of normal variation (two-tailed), which
in a dashboard with ~10 services across GCP + AWS would mean roughly one
false fire every two days. 3σ fires on ~0.3%, which at the same cardinality
is roughly one false fire per month - matching the project's "warn only on
real signal" posture. Tune if your service set is much larger or smaller.
