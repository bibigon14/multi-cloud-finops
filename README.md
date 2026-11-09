# multi-cloud-finops

Multi-cloud FinOps cost observability platform. Burn-rate alerts applied to
cloud spend instead of just error budgets - because a forgotten GPU node
at 03:00 UTC is just as much a reliability failure as a crashed pod.

Why this exists: a Senior SRE in 2026 is increasingly asked to own cost as
a reliability signal, not a finance concern. This project ports the SRE
playbook (SLO targets, error budgets, burn-rate alerts, runbook-driven
response) onto cost metrics, and demonstrates it across GCP, AWS, OCI and
Azure in one Grafana.

## What's inside

```
multi-cloud-finops/
├── terraform/            BQ dataset + IAM + Grafana service account
├── queries/              Reference SQL for each export format
├── grafana/              Datasource + dashboards + burn-rate alerts
├── docs/                 Narrative, architecture, FOCUS awareness notes
└── README.md             (you are here)
```

## Status

- **v0.1** - GCP: BigQuery billing export (Standard + Detailed + FOCUS)
  wired, reference queries validated against a live billing account,
  one Grafana dashboard (`MTD by service`), one burn-rate alert
- **v0.2** (next) - AWS: CUR export to S3 + Athena table, second
  datasource in the same Grafana
- **v0.3** - OCI usage report + Azure cost export
- **v0.4** - Cost-per-Kubernetes-namespace attribution via label
  propagation (GKE → BQ detailed export, EKS → CUR resource tags)
- **v0.5** - Anomaly detection (z-score over 7-day rolling baseline)

## v0.1 quickstart (GCP)

Prerequisite: BigQuery billing export enabled in the Cloud Billing console
(Standard, Detailed and FOCUS). See `docs/architecture.md` for the one-time
setup. Data starts flowing within ~24 hours of enablement.

```bash
cd terraform/
terraform init
terraform apply   # creates BQ dataset confirmation, Grafana SA, IAM

cd ..
bq query --use_legacy_sql=false < queries/mtd-by-service.sql
```

Grafana import: `grafana/dashboards/mtd-by-service.json`, pointed at the
BigQuery datasource provisioned by `grafana/datasources/bigquery.yaml`.

## The SRE angle

Every pattern in this repo has a direct parallel in the SRE Workbook:

| SRE concept                  | FinOps equivalent in this repo             |
|------------------------------|--------------------------------------------|
| SLO target                   | Monthly budget ceiling                     |
| Error budget                 | Unspent budget for the period              |
| Burn-rate alert (14.4x / 1h) | "At current spend rate, budget runs out in N days" |
| Runbook                      | `docs/runbooks/budget-burn.md`             |
| Postmortem                   | Monthly spend review with service-level attribution |

A FinOps dashboard that just shows a current-spend number is a status
page. A FinOps dashboard that alerts at a burn rate ratio with an SLO
window is a reliability tool. This repo builds the second kind.

## License

MIT. See `LICENSE`.
