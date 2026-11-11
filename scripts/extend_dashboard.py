#!/usr/bin/env python3
"""Extend the multi-cloud-finops dashboard with an AWS row.

Reads the existing GCP-only dashboard JSON, inserts two row-divider
panels, five AWS panels that mirror the GCP five, and bumps the
title / tags. Keeps the UID the same so the deployed Pi dashboard
URL does not change - the existing GCP panels keep their IDs 1-5
and their original positions at y=0..14.

Idempotent: if an AWS row panel is already present, the script
exits without touching the file.
"""
import json
import sys
from pathlib import Path

PATH = Path.home() / "mnt/multi-cloud-finops/grafana/dashboards/mtd-by-service.json"

with PATH.open() as f:
    d = json.load(f)

if any(p.get("title") == "AWS (CUR 2.0)" for p in d["panels"]):
    print("already extended, nothing to do")
    sys.exit(0)

# All existing GCP panels live between y=0..15. Shift them down by 1
# to make room for a GCP header row at the top.
for p in d["panels"]:
    p["gridPos"]["y"] += 1

# Row-divider panels: one for GCP (over the existing five), one for
# AWS (over the new five). Rows collapse / expand independently.
gcp_row = {
    "id": 100,
    "type": "row",
    "title": "GCP (BigQuery billing export)",
    "collapsed": False,
    "gridPos": {"h": 1, "w": 24, "x": 0, "y": 0},
    "panels": [],
}

AWS_DS = {"type": "grafana-athena-datasource", "uid": "aws-athena-cur"}
TABLE_NAME = "multi_cloud_finops.multi_cloud_finops_cur2"
LINE_ITEM_TYPES = (
    "'Usage', 'DiscountedUsage', 'SavingsPlanCoveredUsage', "
    "'SavingsPlanRecurringFee', 'Fee'"
)
BUDGET_USD = "10.0"

# AWS header + five panels, starting at y=16 (right below the GCP
# bar+timeseries row which ends at y=15 after the shift).
aws_row = {
    "id": 101,
    "type": "row",
    "title": "AWS (CUR 2.0)",
    "collapsed": False,
    "gridPos": {"h": 1, "w": 24, "x": 0, "y": 16},
    "panels": [],
}

aws_mtd = {
    "id": 6,
    "title": "Month-to-date spend (AWS)",
    "type": "stat",
    "gridPos": {"h": 5, "w": 8, "x": 0, "y": 17},
    "datasource": AWS_DS,
    "targets": [{
        "refId": "A",
        "rawSQL": (
            f"SELECT ROUND(COALESCE(SUM(line_item_unblended_cost), 0.0), 2) AS cost_usd "
            f"FROM {TABLE_NAME} "
            f"WHERE billing_period = date_format(current_date, '%Y-%m') "
            f"  AND line_item_line_item_type IN ({LINE_ITEM_TYPES})"
        ),
        "format": "table",
    }],
    "fieldConfig": {
        "defaults": {
            "unit": "currencyUSD",
            "decimals": 2,
            "color": {"mode": "thresholds"},
            "thresholds": {"mode": "absolute", "steps": [
                {"color": "green", "value": None},
                {"color": "yellow", "value": 5},
                {"color": "red", "value": 10},
            ]},
        }
    },
    "options": {
        "colorMode": "background", "graphMode": "none",
        "textMode": "value", "justifyMode": "auto",
    },
}

aws_burn = {
    "id": 7,
    "title": "Burn rate (AWS, 1.0 = on plan)",
    "type": "stat",
    "gridPos": {"h": 5, "w": 8, "x": 8, "y": 17},
    "datasource": AWS_DS,
    "targets": [{
        "refId": "A",
        "rawSQL": (
            "WITH mtd AS ("
            f"SELECT COALESCE(SUM(line_item_unblended_cost), 0.0) AS spend "
            f"FROM {TABLE_NAME} "
            f"WHERE billing_period = date_format(current_date, '%Y-%m') "
            f"  AND line_item_line_item_type IN ({LINE_ITEM_TYPES})"
            "), cal AS ("
            "SELECT day_of_month(current_date) AS d, "
            "       day_of_month(last_day_of_month(current_date)) AS dm"
            ") "
            "SELECT ROUND("
            f"  (mtd.spend / NULLIF({BUDGET_USD}, 0)) / "
            "  NULLIF(CAST(cal.d AS DOUBLE) / cal.dm, 0), 2"
            ") AS burn_rate FROM mtd, cal"
        ),
        "format": "table",
    }],
    "fieldConfig": {
        "defaults": {
            "unit": "none",
            "decimals": 2,
            "color": {"mode": "thresholds"},
            "thresholds": {"mode": "absolute", "steps": [
                {"color": "green", "value": None},
                {"color": "yellow", "value": 1.0},
                {"color": "red", "value": 1.5},
            ]},
        }
    },
    "options": {
        "colorMode": "background", "graphMode": "none",
        "textMode": "value", "justifyMode": "auto",
    },
}

aws_projected = {
    "id": 8,
    "title": "Projected month-end (AWS)",
    "type": "stat",
    "gridPos": {"h": 5, "w": 8, "x": 16, "y": 17},
    "datasource": AWS_DS,
    "targets": [{
        "refId": "A",
        "rawSQL": (
            "WITH mtd AS ("
            f"SELECT COALESCE(SUM(line_item_unblended_cost), 0.0) AS spend "
            f"FROM {TABLE_NAME} "
            f"WHERE billing_period = date_format(current_date, '%Y-%m') "
            f"  AND line_item_line_item_type IN ({LINE_ITEM_TYPES})"
            "), cal AS ("
            "SELECT day_of_month(current_date) AS d, "
            "       day_of_month(last_day_of_month(current_date)) AS dm"
            ") "
            "SELECT ROUND((mtd.spend / NULLIF(cal.d, 0)) * cal.dm, 2) AS projected "
            "FROM mtd, cal"
        ),
        "format": "table",
    }],
    "fieldConfig": {
        "defaults": {
            "unit": "currencyUSD",
            "decimals": 2,
            "color": {"mode": "thresholds"},
            "thresholds": {"mode": "absolute", "steps": [
                {"color": "green", "value": None},
                {"color": "yellow", "value": 8},
                {"color": "red", "value": 10},
            ]},
        }
    },
    "options": {
        "colorMode": "background", "graphMode": "none",
        "textMode": "value", "justifyMode": "auto",
    },
}

aws_bar = {
    "id": 9,
    "title": "MTD cost by service (AWS)",
    "type": "barchart",
    "gridPos": {"h": 10, "w": 12, "x": 0, "y": 22},
    "datasource": AWS_DS,
    "targets": [{
        "refId": "A",
        "rawSQL": (
            "SELECT product_servicename AS service, "
            "       ROUND(SUM(line_item_unblended_cost), 4) AS cost_usd "
            f"FROM {TABLE_NAME} "
            f"WHERE billing_period = date_format(current_date, '%Y-%m') "
            f"  AND line_item_line_item_type IN ({LINE_ITEM_TYPES}) "
            "GROUP BY product_servicename "
            "ORDER BY cost_usd DESC LIMIT 20"
        ),
        "format": "table",
    }],
    "fieldConfig": {"defaults": {"unit": "currencyUSD", "decimals": 4}},
    "options": {
        "orientation": "horizontal",
        "xField": "service",
        "legend": {"showLegend": False},
    },
}

aws_trend = {
    "id": 10,
    "title": "Daily spend trend (AWS, last 30 days)",
    "type": "timeseries",
    "gridPos": {"h": 10, "w": 12, "x": 12, "y": 22},
    "datasource": AWS_DS,
    "targets": [{
        "refId": "A",
        "rawSQL": (
            "SELECT date_trunc('day', line_item_usage_start_date) AS time, "
            "       product_servicename AS metric, "
            "       SUM(line_item_unblended_cost) AS value "
            f"FROM {TABLE_NAME} "
            "WHERE billing_period IN ("
            "    date_format(current_date, '%Y-%m'),"
            "    date_format(current_date - interval '1' month, '%Y-%m')"
            "  ) "
            "  AND line_item_usage_start_date >= current_date - interval '30' day "
            f"  AND line_item_line_item_type IN ({LINE_ITEM_TYPES}) "
            "GROUP BY 1, 2 ORDER BY 1"
        ),
        "format": "time_series",
    }],
    "fieldConfig": {
        "defaults": {
            "unit": "currencyUSD",
            "custom": {
                "drawStyle": "bars",
                "lineWidth": 1,
                "fillOpacity": 70,
                "stacking": {"mode": "normal", "group": "A"},
            },
        }
    },
    "options": {"legend": {"displayMode": "list", "placement": "bottom"}},
}

d["panels"] = [gcp_row] + d["panels"] + [aws_row, aws_mtd, aws_burn, aws_projected, aws_bar, aws_trend]
d["title"] = "Multi-cloud cost - MTD + burn rate"
d["tags"] = sorted(set(d.get("tags", []) + ["finops", "gcp", "aws", "billing", "burn-rate", "multi-cloud"]))
d["version"] = d.get("version", 1) + 1

PATH.write_text(json.dumps(d, indent=2) + "\n")
print(f"extended {PATH} - {len(d['panels'])} panels total, title='{d['title']}'")
