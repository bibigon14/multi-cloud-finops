-- Same MTD readout as mtd-by-service.sql, but reading from the FOCUS
-- export table. Shape matches the FinOps Foundation FOCUS 1.0 spec so
-- the same query will run against AWS CUR 2.0, Azure Cost Export and
-- OCI Usage Report once those vendors publish compliant exports.
--
-- Multi-cloud readouts land here once v0.2/v0.3 ship. For v0.1 this
-- demonstrates that one query plan works over the standard schema.
SELECT
  ServiceName,
  ROUND(SUM(BilledCost), 4) AS billed_cost_usd,
  ROUND(SUM(EffectiveCost), 4) AS effective_cost_usd
FROM `dstepanov-gke-platform.gcp_billing_immutable_0108CD_97A262_B94181_us.*`
WHERE _TABLE_SUFFIX LIKE 'focus_v1%'
  AND BillingPeriodStart <= CURRENT_TIMESTAMP()
  AND BillingPeriodEnd   >  CURRENT_TIMESTAMP()
GROUP BY ServiceName
ORDER BY effective_cost_usd DESC;
