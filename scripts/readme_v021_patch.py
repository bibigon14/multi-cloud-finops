#!/usr/bin/env python3
"""Patch README.md for v0.2.1 ship (AWS data delivered).

Idempotent: if the v0.2.1 entry is already in place, exits without touching
the file.

- Inserts a v0.2.1 entry at the top of the Status section (above v0.2).
- Keeps v0.2 "No data" framing intact as the ship-day story and shows the
  v0.2.1 "data delivered" screenshots as the follow-up.
"""
from pathlib import Path
import sys

PATH = Path.home() / "mnt/multi-cloud-finops/README.md"

src = PATH.read_text()
if "v0.2.1 (2026-11-11)" in src:
    print("already patched, nothing to do")
    sys.exit(0)

V021_ENTRY = """- **v0.2.1 (2026-11-11)** - AWS data delivered, money-shot captured.
  CUR 2.0 first drop arrived ~24h after v0.2 enablement, nightly Glue
  crawler catalogued the partition, Athena datasource in Grafana started
  returning live numbers. Panel queries then surfaced three real CUR 2.0
  schema facts the ship-day code had gotten wrong (`SELECT *` not accepted
  on CreateExport; `BILLING_VIEW_ARN` returned on every GetExport response
  and the hashicorp/aws 5.100 provider trips on it when it is absent from
  the plan; the flat column is `product_servicecode` - `AmazonEC2`,
  `AmazonEKS`, etc - not `product_servicename`), all three fixed and
  documented inline next to the resource they came from. One day of GCP
  Autopilot + AWS EKS workload is enough to tell the SRE story in the
  numbers.

  ![GCP cost row - BigQuery billing export, MTD $4.40, burn rate 1.20 (within budget), projected $12.00; Compute Engine + Kubernetes Engine dominate](docs/screenshots/02-mtd-dashboard-gcp.png)

  ![AWS cost row - CUR 2.0 via Athena, MTD $6.34, burn rate 1.73 (overrunning), projected $17.29; AmazonEKS control plane is 87% of spend, exactly the managed-service cost lesson every FinOps review teaches](docs/screenshots/03-mtd-dashboard-aws.png)

  Side-by-side the two rows carry the actual portfolio point: same SRE
  burn-rate SLO pattern over two clouds, same dashboard, same `Last 30
  days` window, same green/yellow/red thresholds. The GCP side is
  on-plan; the AWS side is overrunning because EKS control plane fee
  ($0.10/h) compounded over two days already ate most of a $10 ceiling.
  That is a real FinOps conversation starter, not a demo screenshot.

"""

anchor = "- **v0.2 (2026-11-10)**"
if anchor not in src:
    sys.exit("v0.2 anchor not found - README restructured?")
src = src.replace(anchor, V021_ENTRY + anchor, 1)

PATH.write_text(src)
print(f"patched {PATH}")
