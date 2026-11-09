-- Month-to-date cost attributed to Kubernetes namespaces.
--
-- Reads the Detailed usage cost export (per-resource, per-label). GKE
-- auto-propagates two labels on node and PD line items when the
-- "GKE cost allocation" feature is enabled on the cluster:
--     goog-k8s-cluster-name
--     goog-k8s-cluster-location
--
-- For per-namespace / per-workload attribution, enable "Kubernetes
-- resource usage export" on the cluster. That also puts:
--     goog-k8s-namespace
--     goog-k8s-workload-name
-- on the line items for nodes and persistent disks.
--
-- Line items without these labels (control plane, standalone network,
-- Cloud Logging, etc.) fall into the 'untagged' bucket - they are
-- real cost and belong in the readout, not quietly dropped.
SELECT
  COALESCE(
    (SELECT value FROM UNNEST(labels) WHERE key = 'goog-k8s-namespace'),
    'untagged'
  ) AS namespace,
  COALESCE(
    (SELECT value FROM UNNEST(labels) WHERE key = 'goog-k8s-cluster-name'),
    'n/a'
  ) AS cluster,
  service.description AS service,
  ROUND(SUM(cost), 4) AS cost_usd
FROM `dstepanov-gke-platform.billing_export.gcp_billing_export_resource_v1_0108CD_97A262_B94181`
WHERE _PARTITIONTIME >= TIMESTAMP(DATE_TRUNC(CURRENT_DATE(), MONTH))
GROUP BY namespace, cluster, service
ORDER BY cost_usd DESC
LIMIT 50;
