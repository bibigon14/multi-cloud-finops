-- v0.6 - GCP cost anomaly detection via z-score against a 7-day rolling baseline.
--
-- For each (service, day) pair in the last 14 days, computes the mean and
-- stddev of the 7 preceding days' spend for the same service, then emits
-- a z-score for today:
--
--     z = (today_cost - baseline_mean) / baseline_stddev
--
-- Rows the Grafana anomaly panel highlights (sorted by |z| DESC):
--
--     |z| < 2   normal
--     |z| 2..3  warning
--     |z| >= 3  critical  (also what the Grafana alert rule trips on)
--
-- A separate noise floor filters services whose baseline mean is below
-- $0.05/day. On a $10/month portfolio the long tail of near-zero services
-- would otherwise inflate z-scores on cent-level daily blips. Tune the
-- threshold at the top if the budget changes.
--
-- First-week false positives: a service with fewer than 5 of 7 preceding
-- days available gets z-score NULL; Grafana filters those out.

DECLARE noise_floor_usd  NUMERIC DEFAULT 0.05;    -- min baseline mean/day
DECLARE min_history_days INT64   DEFAULT 5;       -- out of 7 preceding

WITH daily AS (
  SELECT
    DATE(usage_start_time)                              AS day,
    service.description                                 AS service,
    ROUND(SUM(cost), 4)                                 AS cost_usd
  FROM `dstepanov-gke-platform.billing_export.gcp_billing_export_v1_0108CD_97A262_B94181`
  WHERE DATE(_PARTITIONTIME) >= DATE_SUB(CURRENT_DATE(), INTERVAL 30 DAY)
    AND cost > 0
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
    ORDER BY UNIX_DATE(day)
    RANGE BETWEEN 7 PRECEDING AND 1 PRECEDING
  )
)
SELECT
  day,
  service,
  cost_usd,
  ROUND(baseline_mean,   4) AS baseline_mean,
  ROUND(baseline_stddev, 4) AS baseline_stddev,
  baseline_days,
  ROUND(SAFE_DIVIDE(cost_usd - baseline_mean, NULLIF(baseline_stddev, 0)), 2) AS z_score,
  CASE
    WHEN baseline_days < min_history_days                                  THEN 'insufficient-history'
    WHEN baseline_mean < noise_floor_usd                                   THEN 'below-noise-floor'
    WHEN ABS(SAFE_DIVIDE(cost_usd - baseline_mean, NULLIF(baseline_stddev, 0))) >= 3 THEN 'critical'
    WHEN ABS(SAFE_DIVIDE(cost_usd - baseline_mean, NULLIF(baseline_stddev, 0))) >= 2 THEN 'warning'
    ELSE 'normal'
  END AS status
FROM baselined
WHERE day >= DATE_SUB(CURRENT_DATE(), INTERVAL 14 DAY)
ORDER BY day DESC, ABS(IFNULL(SAFE_DIVIDE(cost_usd - baseline_mean, NULLIF(baseline_stddev, 0)), 0)) DESC;
