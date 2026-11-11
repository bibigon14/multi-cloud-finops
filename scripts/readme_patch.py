#!/usr/bin/env python3
"""Patch README.md for v0.2 ship.

Idempotent: if the v0.2 entry is already in place, exits without touching
the file.

- Inserts a v0.2 entry at the top of the Status section (above v0.1.1).
- Rewrites the old "(next)" placeholder under v0.2 in the roadmap to
  reference OCI/Azure as the next milestone (now v0.3 in line).
- Renames "v0.1 quickstart (GCP)" to a joint quickstart that covers
  both clouds, with the AWS bits appended after the GCP ones.
"""
from pathlib import Path
import sys

PATH = Path.home() / "mnt/multi-cloud-finops/README.md"

src = PATH.read_text()
if "v0.2 (2026-11-10)" in src:
    print("already patched, nothing to do")
    sys.exit(0)

# --- Insert the new v0.2 entry above v0.1.1 ------------------------------

V02_ENTRY = """- **v0.2 (2026-11-10)** - AWS joins the multi-cloud dashboard.
  Cost and Usage Report 2.0 export enabled in the live AWS account via
  `aws_bcmdataexports_export`, writing hourly PARQUET to a dedicated
  S3 bucket with lifecycle to GLACIER_IR at 90 days. Athena workgroup
  with a 10 GiB per-query scan cap, Glue database, and a daily
  schedule-driven Glue crawler. Dedicated IAM user `grafana-athena-reader`
  (console access off) with a scoped policy that covers exactly the
  workgroup, the Glue catalog entries for this database, and the two
  S3 buckets involved - no `AmazonAthenaFullAccess` wildcard. Grafana
  Athena datasource added as the second datasource on the same Pi;
  dashboard now carries a parallel AWS row (MTD, burn rate, projected
  month-end, bar by service, 30-day stacked trend) mirroring the GCP
  row, with the two rows ready to combine through Grafana Mixed mode
  for v0.4 unified-totals work.

  CUR 2.0 delivers its first report within ~24 hours of enablement,
  so the AWS panels show "No data" on the ship-day screenshot and
  populate overnight. Expected behaviour, documented out loud rather
  than hidden.

"""

anchor = "- **v0.1.1 (2026-11-10)**"
if anchor not in src:
    sys.exit("v0.1.1 anchor not found - README restructured?")
src = src.replace(anchor, V02_ENTRY + anchor, 1)

# --- Roadmap: remove the old (next) stub, promote v0.3 to (next) ---------

OLD_ROADMAP = """- **v0.2** (next) - AWS: CUR export to S3 + Athena table, second
  datasource in the same Grafana
- **v0.3** - OCI usage report + Azure cost export"""
NEW_ROADMAP = """- **v0.3** (next) - OCI usage report + Azure cost export"""
if OLD_ROADMAP not in src:
    sys.exit("roadmap v0.2 stub not found as expected")
src = src.replace(OLD_ROADMAP, NEW_ROADMAP, 1)

# --- Quickstart section: merge AWS into the GCP one ----------------------

OLD_QUICKSTART = """## v0.1 quickstart (GCP)

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
BigQuery datasource provisioned by `grafana/datasources/bigquery.yaml`."""

NEW_QUICKSTART = """## Quickstart

Prerequisite: BigQuery billing export enabled in the Cloud Billing console
(Standard, Detailed and FOCUS), AWS Billing + Data Exports accessible from
the same AWS account. See `docs/architecture.md` for the one-time setup.
Data starts flowing within ~24 hours of enablement on either cloud.

```bash
cd terraform/
terraform init -upgrade
terraform apply   # GCP SA + IAM, AWS S3 + CUR 2.0 + Athena + Glue + IAM user

# Fetch the Grafana AWS creds without echoing them to scrollback:
terraform output -raw grafana_aws_access_key_id
terraform output -raw grafana_aws_secret_key   # paste into Grafana secret store

cd ..
bq query --use_legacy_sql=false < queries/mtd-by-service.sql
# (AWS equivalent runs once CUR 2.0's first delivery lands, ~24h after apply)
aws athena start-query-execution \\
  --work-group multi-cloud-finops \\
  --query-string "$(cat queries/aws-mtd-by-service.sql)"
```

Grafana wiring: `grafana/dashboards/mtd-by-service.json` carries both the
GCP and the AWS rows. BigQuery datasource: provisioned by the bundled
`bigquery.yaml` (datasource UID `bq-billing-export`). Athena datasource:
provisioned as `aws-athena-cur` by `homelab-k3s/grafana/athena.yaml`,
with the access key id and secret key pasted into Grafana's own secret
store (never into the provisioning YAML)."""

if OLD_QUICKSTART not in src:
    sys.exit("v0.1 quickstart block not found as expected")
src = src.replace(OLD_QUICKSTART, NEW_QUICKSTART, 1)

PATH.write_text(src)
print(f"patched {PATH}")
