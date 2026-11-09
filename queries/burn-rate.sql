-- Budget burn rate, SRE-style.
--
-- Idea borrowed from the SRE Workbook burn-rate alert pattern:
--     burn_rate = (actual_consumption_in_window / budget_window_fraction)
-- Applied here to monthly cost:
--     budget_window_fraction = days_elapsed / days_in_month
--     actual_consumption     = spend_so_far / monthly_budget
--     burn_rate              = actual_consumption / budget_window_fraction
--
-- burn_rate == 1.0 → spending exactly on plan
-- burn_rate  < 1.0 → under budget, room to run
-- burn_rate  > 1.0 → overspending, project month-end > budget
-- burn_rate >= 2.0 → runaway, will exceed budget by end of month unless
--                    something changes
--
-- Monthly budget is parameterised. For a hard-coded run against the
-- live billing account, replace @monthly_budget_usd with a literal.
DECLARE monthly_budget_usd FLOAT64 DEFAULT 10.0;

WITH mtd AS (
  SELECT ROUND(SUM(cost), 4) AS spend
  FROM `dstepanov-gke-platform.billing_export.gcp_billing_export_v1_0108CD_97A262_B94181`
  WHERE _PARTITIONTIME >= TIMESTAMP(DATE_TRUNC(CURRENT_DATE(), MONTH))
),
calendar AS (
  SELECT
    EXTRACT(DAY FROM CURRENT_DATE()) AS day_of_month,
    EXTRACT(DAY FROM LAST_DAY(CURRENT_DATE(), MONTH)) AS days_in_month
)
SELECT
  mtd.spend AS spend_so_far_usd,
  monthly_budget_usd AS monthly_budget_usd,
  calendar.day_of_month,
  calendar.days_in_month,
  SAFE_DIVIDE(mtd.spend, monthly_budget_usd) AS budget_consumed_fraction,
  SAFE_DIVIDE(calendar.day_of_month, calendar.days_in_month) AS window_elapsed_fraction,
  ROUND(
    SAFE_DIVIDE(
      SAFE_DIVIDE(mtd.spend, monthly_budget_usd),
      SAFE_DIVIDE(calendar.day_of_month, calendar.days_in_month)
    ),
    2
  ) AS burn_rate,
  ROUND(
    SAFE_DIVIDE(mtd.spend, calendar.day_of_month) * calendar.days_in_month,
    2
  ) AS projected_month_end_usd
FROM mtd, calendar;
