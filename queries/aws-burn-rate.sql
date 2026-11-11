-- Budget burn rate for the AWS side of the house, mirror of
-- queries/burn-rate.sql for GCP.
--
-- Same SRE Workbook arithmetic:
--     budget_window_fraction = days_elapsed / days_in_month
--     actual_consumption     = mtd_spend / monthly_budget
--     burn_rate              = actual_consumption / budget_window_fraction
--
-- burn_rate == 1.0 → spending exactly on plan
-- burn_rate  < 1.0 → under budget, room to run
-- burn_rate  > 1.0 → overspending, project month-end > budget
-- burn_rate >= 2.0 → runaway, will exceed budget by month end unless
--                    something changes
--
-- Athena v3 (Trino) functions used:
--   date_format(date, '%Y-%m')         → '2026-11'  (partition match)
--   last_day_of_month(current_date)    → calendar end of current month
--   date_diff('day', a, b)              → absolute day count
-- All of these are standard on workgroups set to engine version 3.
WITH mtd AS (
  SELECT
    ROUND(COALESCE(SUM(line_item_unblended_cost), 0.0), 4) AS spend
  FROM multi_cloud_finops.multi_cloud_finops_cur2
  WHERE billing_period = date_format(current_date, '%Y-%m')
    AND line_item_line_item_type IN (
      'Usage',
      'DiscountedUsage',
      'SavingsPlanCoveredUsage',
      'SavingsPlanRecurringFee',
      'Fee'
    )
),
calendar AS (
  SELECT
    day_of_month(current_date)             AS day_of_month,
    day_of_month(last_day_of_month(current_date)) AS days_in_month
),
budget AS (
  SELECT 10.0 AS monthly_budget_usd
)
SELECT
  mtd.spend                                             AS spend_so_far_usd,
  budget.monthly_budget_usd                             AS monthly_budget_usd,
  calendar.day_of_month                                 AS day_of_month,
  calendar.days_in_month                                AS days_in_month,
  mtd.spend / NULLIF(budget.monthly_budget_usd, 0)      AS budget_consumed_fraction,
  CAST(calendar.day_of_month AS DOUBLE) /
    NULLIF(calendar.days_in_month, 0)                   AS window_elapsed_fraction,
  ROUND(
    (mtd.spend / NULLIF(budget.monthly_budget_usd, 0)) /
    NULLIF(CAST(calendar.day_of_month AS DOUBLE) / calendar.days_in_month, 0),
    2
  )                                                     AS burn_rate,
  ROUND(
    (mtd.spend / NULLIF(calendar.day_of_month, 0)) * calendar.days_in_month,
    2
  )                                                     AS projected_month_end_usd
FROM mtd, calendar, budget;
