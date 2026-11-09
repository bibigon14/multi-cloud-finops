-- Last 30 days of cost, bucketed by day and service.
-- Feeds the Grafana timeseries for anomaly spotting.
SELECT
  DATE(usage_start_time) AS day,
  service.description AS service,
  ROUND(SUM(cost), 4) AS cost_usd
FROM `dstepanov-gke-platform.billing_export.gcp_billing_export_v1_0108CD_97A262_B94181`
WHERE _PARTITIONTIME >= TIMESTAMP(DATE_SUB(CURRENT_DATE(), INTERVAL 30 DAY))
GROUP BY day, service
ORDER BY day ASC, cost_usd DESC;
