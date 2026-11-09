-- Month-to-date GCP cost grouped by service, in descending order.
-- Reads the Standard usage cost export (monthly rollup, cheapest to query).
--
-- Billing account 0108CD-97A262-B94181 → table suffix uses underscores.
-- Replace both occurrences if porting to another account.
SELECT
  service.description AS service,
  ROUND(SUM(cost), 4) AS cost_usd,
  ROUND(SUM(CASE WHEN c.type = 'PROMOTION' THEN c.amount ELSE 0 END), 4) AS promo_credits_usd,
  ROUND(SUM(cost) + SUM(IFNULL((SELECT SUM(amount) FROM UNNEST(credits)), 0)), 4) AS net_cost_usd
FROM `dstepanov-gke-platform.billing_export.gcp_billing_export_v1_0108CD_97A262_B94181`
LEFT JOIN UNNEST(credits) AS c
WHERE _PARTITIONTIME >= TIMESTAMP(DATE_TRUNC(CURRENT_DATE(), MONTH))
  AND _PARTITIONTIME <  TIMESTAMP(DATE_ADD(DATE_TRUNC(CURRENT_DATE(), MONTH), INTERVAL 1 MONTH))
GROUP BY service
ORDER BY net_cost_usd DESC;
