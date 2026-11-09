# Runbook - budget burn-rate alert

Alert fired: `BudgetBurnRate_FastWindow` or `BudgetBurnRate_SlowWindow`.

Burn rate `N` means spend over the alert window is `N` times the
pace needed to exactly hit the monthly budget by month-end.
`N > 1` = overspending, `N > 14.4` = will exhaust budget in days.

## Triage (<2 min)

1. Open the Grafana dashboard **GCP cost - MTD + burn rate**. Confirm
   the burn-rate stat is still red. If it has returned to green, the
   spike is over - look at the "Daily spend trend" panel to see which
   service spiked and move to postmortem.
2. On the stat **Projected month-end spend**, note the delta vs the
   budget ceiling. That is the real stake, not the burn rate number.
3. On the barchart **MTD cost by service**, find the service whose
   bar grew in the last hour (hover / tooltips). That is almost
   always the culprit.

## Investigate (5-15 min)

For GCE / Compute Engine spikes:

```bash
# running instances across all regions, sorted by machine type
gcloud compute instances list \
  --filter='status=RUNNING' \
  --format='table(name,zone,machineType.basename(),creationTimestamp)' \
  --sort-by=~creationTimestamp | head -20
```

The top of that list is instances created most recently. Anything
`a2-*`, `g2-*`, `a3-*` (GPU) at the top is a forgotten GPU node and
the likely cause.

For GKE / Kubernetes Engine spikes - run the per-namespace query
and look at the delta from yesterday:

```bash
bq query --use_legacy_sql=false < queries/cost-by-k8s-namespace.sql
```

For Cloud Storage spikes:

```bash
gsutil ls -L -r gs://* | awk '/Content-Length/ {s+=$2} END {print s/1024/1024/1024 " GiB"}'
```
...or check any lifecycle policy you recently changed.

## Act

- **Forgotten GPU node**: `gcloud compute instances stop <name> --zone=<zone>`
  and figure out what spawned it before resuming anything. Terraform
  state drift is a common cause.
- **Runaway cron / loop**: pause the workload, patch, resume.
- **Unexpected storage growth**: find the bucket, verify lifecycle
  rules, delete anything you did not mean to keep.

## Close

File a one-paragraph postmortem in the repo under `docs/postmortems/`.
Minimum fields: timestamp, service, root cause, cost impact in USD,
one preventive action. The point is pattern collection, not blame.
