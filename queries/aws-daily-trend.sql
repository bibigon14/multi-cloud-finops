-- Last 30 days of AWS cost, bucketed by day and service. Mirror of
-- queries/daily-trend.sql for GCP.
--
-- CUR 2.0 is partitioned by billing_period (month), so a window that
-- crosses a month boundary has to read both the current and the
-- previous month's partitions. The `line_item_usage_start_date`
-- filter trims the extra month down to the exact 30-day window.
SELECT
  date_trunc('day', line_item_usage_start_date) AS day,
  product_servicecode                           AS service,
  ROUND(SUM(line_item_unblended_cost), 4)       AS cost_usd
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
GROUP BY 1, 2
ORDER BY 1 ASC, 3 DESC;
