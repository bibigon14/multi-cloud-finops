#!/usr/bin/env python3
"""Fetch OCI Usage API data and write a flat JSON for Grafana consumption.

Pattern-wise this mirrors the Grafana Infinity datasource reading the Azure
Cost Management API live. OCI's Usage API uses the OCI Signature auth scheme
(custom HTTP signing, not OAuth2), which Grafana Infinity does not support
natively - so the integration path is: this script runs locally with the user's
OCI config, pulls the usage window, emits a flat JSON document, and the JSON
is served via raw.githubusercontent.com so a static-URL Grafana Infinity
panel can read it unauthenticated.

Output shape is deliberately kept flat:
  {
    "fetched_at": "2026-11-12T...",
    "tenant_id": "ocid1.tenancy.oc1..aaaa...",
    "currency": "USD",
    "query_type": "COST",
    "time_window": "30d",
    "items": [
      {"service": "COMPUTE", "cost": 0.0, "quantity": 339.21,
       "time_start": "2026-10-13T00:00:00Z", "time_end": "2026-10-14T00:00:00Z"},
      ...
    ]
  }

Refresh flow: re-run this script and `git commit scripts/fetch_oci_usage.py
data/oci-usage.json` - the new blob propagates to raw.githubusercontent.com
within seconds. A systemd/launchd timer can automate the loop if real-time
refresh matters, but for an Always Free tenancy whose cost is $0/day most
days, a manual re-run before dashboard screenshots is fine.
"""
import json
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

import oci

CONFIG_PATH = Path.home() / ".oci" / "config"
OUTPUT_PATH = Path(__file__).resolve().parent.parent / "data" / "oci-usage.json"


def main():
    config = oci.config.from_file(file_location=str(CONFIG_PATH))
    tenant_id = config["tenancy"]

    client = oci.usage_api.UsageapiClient(config)

    # Align window to UTC midnights so day buckets match Azure / AWS / GCP
    # grafana panels, which all key off UTC day boundaries for the trend lines.
    now_utc = datetime.now(timezone.utc).replace(hour=0, minute=0, second=0, microsecond=0)
    start = now_utc - timedelta(days=30)

    details = oci.usage_api.models.RequestSummarizedUsagesDetails(
        tenant_id=tenant_id,
        time_usage_started=start,
        time_usage_ended=now_utc,
        granularity="DAILY",
        query_type="COST",
        group_by=["service"],
    )

    response = client.request_summarized_usages(details)

    items = []
    for it in response.data.items:
        items.append({
            "service": it.service or "Unknown",
            "cost": float(it.computed_amount or 0.0),
            "quantity": float(it.computed_quantity or 0.0),
            "unit": it.unit or "",
            "time_start": it.time_usage_started.isoformat().replace("+00:00", "Z")
                          if it.time_usage_started else None,
            "time_end": it.time_usage_ended.isoformat().replace("+00:00", "Z")
                        if it.time_usage_ended else None,
            "currency": it.currency or "USD",
        })

    # Deterministic ordering helps keep git diffs clean across reruns.
    items.sort(key=lambda r: (r["time_start"] or "", r["service"]))

    payload = {
        "fetched_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "tenant_id": tenant_id,
        "currency": "USD",
        "query_type": "COST",
        "time_window": "30d",
        "item_count": len(items),
        "items": items,
    }

    OUTPUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT_PATH.write_text(json.dumps(payload, indent=2) + "\n")
    print(f"Wrote {len(items)} items to {OUTPUT_PATH}")


if __name__ == "__main__":
    sys.exit(main() or 0)
