-- Month-to-date AWS cost grouped by service, in descending order.
-- Reads the CUR 2.0 export catalogued as the `multi_cloud_finops_cur2`
-- table by the daily Glue crawler.
--
-- CUR 2.0 is partitioned by billing_period (one partition per month,
-- e.g. '2026-11'). Filtering on it lets Athena skip every closed
-- month and keeps the per-query scan cost under a few MB.
--
-- line_item_line_item_type is filtered to the shapes that count as
-- real spend. Excluding 'Tax', 'Credit', 'Refund', 'EdpDiscount',
-- 'RIVolumeDiscount' and friends matches what the AWS Billing
-- console reports under "Service spend", so this query and the
-- console agree on the same number.
SELECT
  product_servicename AS service,
  ROUND(SUM(line_item_unblended_cost), 4) AS cost_usd,
  ROUND(SUM(CASE WHEN line_item_line_item_type = 'Credit'  THEN line_item_unblended_cost ELSE 0 END), 4) AS credits_usd,
  ROUND(SUM(CASE WHEN line_item_line_item_type = 'Refund'  THEN line_item_unblended_cost ELSE 0 END), 4) AS refunds_usd
FROM multi_cloud_finops.multi_cloud_finops_cur2
WHERE billing_period = date_format(current_date, '%Y-%m')
  AND line_item_line_item_type IN (
    'Usage',
    'DiscountedUsage',
    'SavingsPlanCoveredUsage',
    'SavingsPlanRecurringFee',
    'SavingsPlanNegation',
    'Fee'
  )
GROUP BY product_servicename
ORDER BY cost_usd DESC
LIMIT 50;
