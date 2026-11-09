# Architecture - v0.1 (GCP)

## Data flow

```
Cloud Billing  ──► BigQuery billing exports ──► Grafana ──► Alerts
    (GCP)            (dstepanov-gke-platform.             (burn rate,
                      billing_export.*                     anomaly)
                      + gcp_billing_immutable_*)
```

Three exports are enabled in parallel:

| Export | Schema | Write cadence | Used for |
|---|---|---|---|
| Standard usage cost | per-SKU per-day, no resource ID | daily | MTD rollups, burn-rate alert |
| Detailed usage cost | per-SKU per-day **+ resource_id + labels** | daily | cost-per-namespace, per-workload attribution |
| FOCUS usage cost | FinOps Foundation 1.0 spec | daily | multi-cloud queries in v0.2+ |

Standard and Detailed write into the `billing_export` dataset managed
by this repo (`terraform/main.tf` pins it). FOCUS writes into an
immutable dataset GCP provisions itself (`gcp_billing_immutable_*`),
subject to a 2-year TTL.

## Why three exports

Each schema answers a different question:

- **Standard**: "What did we spend this month, broken down by service?"
  Cheap to query (small table), good enough for the top-of-dashboard
  stats and the burn-rate alert.
- **Detailed**: "Which namespace / workload / disk cost the money?"
  Resource ID and labels make attribution possible. Required for
  showback / chargeback.
- **FOCUS**: "Will the same query run against AWS and OCI tomorrow?"
  Compliant with the FinOps Foundation standard. Lets v0.2+ build
  one query that fans out across clouds instead of maintaining three
  dialect-specific copies.

## Terraform scope

Terraform does NOT provision the billing exports themselves - as of
2026, GCP exposes them only through the Cloud Billing console and the
`cloudbilling.googleapis.com` REST API, with no first-class Terraform
resource. The dataset and the export sink are created once in the
console, documented here, and then everything downstream (dataset IAM,
Grafana service account, key rotation) is Terraform-managed.

This is a legitimate out-of-band dependency: the console is the only
supported API for the export sink, and documenting that honestly
beats hiding it behind a `local-exec` provisioner that would be fragile
and hard to audit.

## IAM

Two principals touch the billing dataset:

- **The billing exporter itself** - managed by Google. No IAM binding
  for us to make.
- **The Grafana service account** (`grafana-bq-reader`) - gets
  `roles/bigquery.dataViewer` on the dataset and `roles/bigquery.jobUser`
  on the project. Dataset-level grant intentionally narrower than
  project-level `roles/bigquery.user`: this SA cannot see any other
  data in the project, cannot create datasets, cannot modify tables.

## Where this goes next

v0.2 adds AWS Cost and Usage Report (CUR 2.0) to S3 + Athena, and
plugs that in as a second datasource in the same Grafana. The dashboard
layout stays the same; a new row shows AWS alongside GCP. The FOCUS
query in `queries/focus-mtd.sql` already has the right shape to
federate across both once AWS CUR 2.0 FOCUS view is enabled.

v0.4 is the interesting one: cost-per-Kubernetes-namespace attribution.
On GKE that needs cluster-level "GKE cost allocation" + "Kubernetes
resource usage export"; on EKS it needs resource tags propagated from
pod labels via a controller. Neither is zero-setup but both are
one-time.
