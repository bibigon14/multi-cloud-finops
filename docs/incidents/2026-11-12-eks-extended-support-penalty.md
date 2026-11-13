# Incident: EKS Extended Support penalty, +$25 over 46 hours

**Date:** 2026-11-10 to 2026-11-12
**Severity:** Low (cost, not availability)
**Detected by:** Billing audit after teardown
**Author:** Dmitry Stepanov

## Summary

EKS cluster `finops-demo` was created on 2026-11-10 at 17:37 PT via `eksctl
create cluster` using the default Kubernetes version `1.31`. That version left
Standard Support in November 2025 and was in the Extended Support window at
creation time, which adds a `$0.50/hr` penalty on top of the `$0.10/hr`
Standard control-plane price. Over the 46 hours the cluster ran for the v0.4
+ v0.5 demos it accrued `$25.34` instead of the `$4.60` a Standard-Support
version would have billed - a 5.5x overcharge, 83% of the total AWS spend for
the window.

## Timeline

| When (PT) | Event |
|-----------|-------|
| 2026-11-10 17:37 | `eksctl create cluster --name finops-demo --region us-east-1` - no `--version` flag, default = 1.31 |
| 2026-11-10 17:50 | Managed nodegroup created, cluster `CREATE_COMPLETE` |
| 2026-11-10 - 2026-11-12 | Cluster runs for v0.4 OCI + v0.4.1 Cloudflare + v0.5 K8s namespace demos |
| 2026-11-12 15:12 | `aws eks delete-nodegroup` + `aws eks delete-cluster` |
| 2026-11-12 16:28 | Billing audit shows AmazonEKS MTD = `$25.34` |
| 2026-11-13 09:28 | AWS CUR 2.0 finalizes - total AWS MTD `$33.48` (EKS is 76%) |

## Root cause

Two-part:

1. `eksctl` default `--version` tracks the most recent *Generally Available*
   Kubernetes release, which for most of a given version's lifetime means
   Standard Support. But EKS lifecycle has **two** windows per version:
   - **Standard Support**: ~14 months from EKS GA, `$0.10/hr` control plane
   - **Extended Support**: ~26 months after Standard ends, `$0.60/hr`
     control plane (that's $0.10 base + $0.50 penalty)
   `1.31` entered Extended Support in November 2025, so a cluster created in
   November 2026 immediately paid the penalty.

2. No pre-create version check in the project's own workflow. We ship a
   multi-cloud FinOps observability dashboard but did not validate the
   lifecycle state of the control plane we were about to run for the demo.

## Impact

- `$25.34` EKS control plane over 46 hours - 5.5x the Standard-Support cost
- `$0` availability impact (cost-only)
- `$0` data impact

## What would have changed the outcome

```bash
# What actually happened (default version resolved to Extended Support):
eksctl create cluster --name finops-demo --region us-east-1

# What should have happened (pin to current Standard Support version):
eksctl create cluster --name finops-demo --region us-east-1 --version=1.33
# or whichever release is currently under Standard Support at create time
```

`eksctl` exposes `--version`; AWS exposes current Standard-Support windows
through `aws eks describe-cluster-versions` and the EKS docs. Checking either
before a demo cluster goes up catches the penalty before it bills.

## Follow-up

- [x] 2026-11-12: cluster + nodegroup torn down
- [x] 2026-11-12: CloudFormation stacks (incl. the orphan `eks-cluster-sg`)
      cleared, VPC gone
- [x] 2026-11-13: this postmortem filed
- [x] 2026-11-13: pre-flight check shipped as `scripts/eksctl-safe-create.sh` -
      wraps `eksctl create cluster`, requires explicit `--version`, refuses
      versions in EKS Extended Support via `aws eks describe-cluster-versions`
- [ ] Mirror: GKE and AKS have the same lifecycle windows - add similar
      lifecycle-state checks to any future scripted cluster provisioning

## Lessons

**"Default managed-service version" is a FinOps smell on every cloud.**
EKS, GKE, AKS and OCI OKE all have Standard/Extended Support splits with
penalty pricing on versions past Standard. Shipping a multi-cloud FinOps
dashboard without pinning versions on the clusters we demo on is exactly
the kind of blind-spot the dashboard was supposed to expose - a reminder
that observability tools need the same operational discipline they
measure.
