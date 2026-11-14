-- v0.6 - AWS cost anomaly detection via z-score against a 7-day rolling baseline.
-- Mirror of queries/anomaly-zscore.sql for AWS CUR 2.0 over Athena.
--
-- Same output shape as the GCP version so the Grafana panel can union
-- them transparently. Trino-flavoured syntax for Athena:
--   - date_trunc('day', ...) instead of BigQuery's DATE()
--   - date_diff + date_add instead of DATE_SUB / INTERVAL arithmetic
--   - try_cast / nullif for the safe division
--
-- CUR 2.0 is partitioned by `billing_period` (YYYY-MM). A 30-day window
-- that crosses a month boundary has to read both the current and the
-- previous month's partitions, hence the IN (...) filter.

WITH daily AS (
  SELECT
    date_trunc('day', line_item_usage_start_date)  AS day,
    product_servicecode                            AS service,
    ROUND(SUM(line_item_unblended_cost), 4)        AS cost_usd
  FROM multi_cloud_finops.data
  WHERE billing_period IN (
      date_format(current_date, '%Y-%m'),
      date_format(current_date - interval '1' month, '%Y-%m')
    )
    AND line_item_usage_start_date >= current_date - interval '30' day
    AND line_item_line_item_type IN (
      'Usage',
      'DiscountedUsage',
      'SavingsPlanCoveredUsage',
      'SavingsPlanRecurringFee',
      'Fee'
    )
    AND line_item_unblended_cost > 0
  GROUP BY 1, 2
),
baselined AS (
  SELECT
    day,
    service,
    cost_usd,
    AVG(cost_usd)    OVER w AS baseline_mean,
    STDDEV(cost_usd) OVER w AS baseline_stddev,
    COUNT(*)         OVER w AS baseline_days
  FROM daily
  WINDOW w AS (
    PARTITION BY service
    ORDER BY day
    RANGE BETWEEN INTERVAL '7' DAY PRECEDING AND INTERVAL '1' DAY PRECEDING
  )
)
SELECT
  day,
  service,
  cost_usd,
  ROUND(baseline_mean,   4) AS baseline_mean,
  ROUND(baseline_stddev, 4) AS baseline_stddev,
  baseline_days,
  ROUND((cost_usd - baseline_mean) / nullif(baseline_stddev, 0), 2) AS z_score,
  CASE
    WHEN baseline_days < 5                                                       THEN 'insufficient-history'
    WHEN baseline_mean < 0.05                                                    THEN 'below-noise-floor'
    WHEN ABS((cost_usd - baseline_mean) / nullif(baseline_stddev, 0)) >= 3       THEN 'critical'
    WHEN ABS((cost_usd - baseline_mean) / nullif(baseline_stddev, 0)) >= 2       THEN 'warning'
    ELSE 'normal'
  END AS status
FROM baselined
WHERE day >= current_date - interval '14' day
ORDER BY day DESC,
         ABS(COALESCE((cost_usd - baseline_mean) / nullif(baseline_stddev, 0), 0)) DESC;
