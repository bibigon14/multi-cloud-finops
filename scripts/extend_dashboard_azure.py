#!/usr/bin/env python3
"""Extend the multi-cloud-finops dashboard with an Azure row.

Reads the dashboard JSON, inserts a new row-divider plus three Azure
panels (MTD stat, bar by service, daily trend) that read from the
Azure Cost Management ARM API via the Grafana Infinity datasource.

Idempotent: if an Azure row is already present, the script exits
without touching the file.

Azure Cost Management API returns responses shaped like
    {"properties": {"columns": [...], "rows": [[..], [..]]}}
Infinity's JSON backend parser flattens `$.properties.rows` into a
table where column order matches the `columns` array. That is the
shape the panels query.
"""
import json
import sys
from pathlib import Path

PATH = Path.home() / "mnt/multi-cloud-finops/grafana/dashboards/mtd-by-service.json"

with PATH.open() as f:
    d = json.load(f)

if any(p.get("title") == "Azure (Cost Management)" for p in d["panels"]):
    print("already extended, nothing to do")
    sys.exit(0)

AZURE_DS = {"type": "yesoreyeram-infinity-datasource", "uid": "azure-cost-management"}
SUB = "c395c797-0fbf-40e6-b1f8-b9a1eee8d838"
# Cost Management query endpoint
URL = (
    f"https://management.azure.com/subscriptions/{SUB}"
    "/providers/Microsoft.CostManagement/query?api-version=2024-08-01"
)

# Body templates
BODY_MTD_TOTAL = json.dumps({
    "type": "ActualCost",
    "timeframe": "MonthToDate",
    "dataset": {
        "granularity": "None",
        "aggregation": {"totalCost": {"name": "Cost", "function": "Sum"}},
    },
})
BODY_MTD_BY_SERVICE = json.dumps({
    "type": "ActualCost",
    "timeframe": "MonthToDate",
    "dataset": {
        "granularity": "None",
        "aggregation": {"totalCost": {"name": "Cost", "function": "Sum"}},
        "grouping": [{"type": "Dimension", "name": "ServiceName"}],
    },
})
BODY_DAILY_30D = json.dumps({
    "type": "ActualCost",
    "timeframe": "BillingMonthToDate",
    "dataset": {
        "granularity": "Daily",
        "aggregation": {"totalCost": {"name": "Cost", "function": "Sum"}},
        "grouping": [{"type": "Dimension", "name": "ServiceName"}],
    },
})

# Panels. Azure row sits below the AWS row (which ends at y=32), so the
# header goes at y=33 and the three new panels at y=34.
azure_row = {
    "id": 102,
    "type": "row",
    "title": "Azure (Cost Management)",
    "collapsed": False,
    "gridPos": {"h": 1, "w": 24, "x": 0, "y": 33},
    "panels": [],
}

def infinity_target(ref_id, url, body, columns, root_selector="properties.rows"):
    """Infinity backend parser target for a POST JSON ARM query."""
    return {
        "refId": ref_id,
        "type": "json",
        "source": "url",
        "format": "table",
        "url": url,
        "url_options": {
            "method": "POST",
            "data": body,
            "body_type": "raw",
            "body_content_type": "application/json",
        },
        "parser": "backend",
        "root_selector": root_selector,
        "columns": columns,
        "filters": [],
        "computed_columns": [],
        "global_query_id": "",
    }

azure_mtd = {
    "id": 11,
    "title": "Month-to-date spend (Azure)",
    "type": "stat",
    "gridPos": {"h": 5, "w": 8, "x": 0, "y": 34},
    "datasource": AZURE_DS,
    "targets": [infinity_target(
        "A", URL, BODY_MTD_TOTAL,
        [
            {"selector": "0", "text": "cost_usd", "type": "number"},
            {"selector": "1", "text": "currency", "type": "string"},
        ],
    )],
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
        },
        "overrides": [
            {"matcher": {"id": "byName", "options": "currency"},
             "properties": [{"id": "custom.hidden", "value": True}]},
        ],
    },
    "options": {
        "colorMode": "background", "graphMode": "none",
        "textMode": "value", "justifyMode": "auto",
        "reduceOptions": {"calcs": ["lastNotNull"], "fields": "/^cost_usd$/", "values": False},
    },
}

azure_bar = {
    "id": 12,
    "title": "MTD cost by service (Azure)",
    "type": "barchart",
    "gridPos": {"h": 10, "w": 12, "x": 0, "y": 39},
    "datasource": AZURE_DS,
    "targets": [infinity_target(
        "A", URL, BODY_MTD_BY_SERVICE,
        [
            {"selector": "0", "text": "cost_usd", "type": "number"},
            {"selector": "1", "text": "service", "type": "string"},
            {"selector": "2", "text": "currency", "type": "string"},
        ],
    )],
    "fieldConfig": {
        "defaults": {"unit": "currencyUSD", "decimals": 4},
        "overrides": [
            {"matcher": {"id": "byName", "options": "currency"},
             "properties": [{"id": "custom.hidden", "value": True}]},
        ],
    },
    "options": {
        "orientation": "horizontal",
        "xField": "service",
        "legend": {"showLegend": False},
    },
}

azure_trend = {
    "id": 13,
    "title": "Daily spend trend (Azure, billing month)",
    "type": "timeseries",
    "gridPos": {"h": 10, "w": 12, "x": 12, "y": 39},
    "datasource": AZURE_DS,
    "targets": [infinity_target(
        "A", URL, BODY_DAILY_30D,
        [
            {"selector": "0", "text": "value", "type": "number"},
            {"selector": "1", "text": "day_int", "type": "number"},
            {"selector": "2", "text": "metric", "type": "string"},
            {"selector": "3", "text": "currency", "type": "string"},
        ],
    )],
    "fieldConfig": {
        "defaults": {
            "unit": "currencyUSD",
            "custom": {
                "drawStyle": "bars",
                "lineWidth": 1,
                "fillOpacity": 70,
                "stacking": {"mode": "normal", "group": "A"},
            },
        },
        "overrides": [
            {"matcher": {"id": "byName", "options": "currency"},
             "properties": [{"id": "custom.hidden", "value": True}]},
            # day_int is YYYYMMDD integer from ARM; convert to time via transform
            {"matcher": {"id": "byName", "options": "day_int"},
             "properties": [
                 {"id": "unit", "value": "dateTimeAsIso"},
             ]},
        ],
    },
    "options": {"legend": {"displayMode": "list", "placement": "bottom"}},
    # Transform: parse day_int as YYYYMMDD → unix ms
    "transformations": [
        {
            "id": "calculateField",
            "options": {
                "mode": "binary",
                "alias": "time",
                "binary": {
                    "left": "day_int",
                    "operator": "*",
                    "right": "1",
                },
            },
        },
        {
            "id": "convertFieldType",
            "options": {
                "conversions": [
                    {"targetField": "time", "destinationType": "time", "dateFormat": "YYYYMMDD"},
                ],
            },
        },
    ],
}

d["panels"].extend([azure_row, azure_mtd, azure_bar, azure_trend])
d["tags"] = sorted(set(d.get("tags", []) + ["azure"]))
d["version"] = d.get("version", 1) + 1

PATH.write_text(json.dumps(d, indent=2) + "\n")
print(f"extended {PATH} - {len(d['panels'])} panels total")
