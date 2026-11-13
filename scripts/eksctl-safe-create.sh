#!/usr/bin/env bash
#
# eksctl-safe-create.sh
#
# Wrapper around `eksctl create cluster` that refuses to run without an
# explicit `--version` flag AND verifies that version is still in EKS
# Standard Support, not Extended.
#
# Why: `eksctl create cluster` without `--version` picks the latest GA
# release, which for most of its lifetime is in Extended Support (an
# extra $0.50/hr penalty on top of $0.10/hr Standard - 6x the base price).
# A v0.5 demo in November 2026 paid $25.34 over 46 hours on a cluster
# that would have cost $4.60 on a Standard-Support version. See
# docs/incidents/2026-11-12-eks-extended-support-penalty.md.
#
# Usage:
#   ./scripts/eksctl-safe-create.sh [any eksctl args] --version=X.Y
#
# Example:
#   ./scripts/eksctl-safe-create.sh --name finops-demo \
#     --region us-east-1 --version=1.33 --nodegroup-name ng \
#     --nodes 2 --node-type t3.small --spot

set -euo pipefail

# 1. Require --version in the args
if ! printf '%s\n' "$@" | grep -qE '^--version($|=)'; then
  echo "ERROR: --version is required." >&2
  echo "Run \`aws eks describe-cluster-versions --output table\` to list" >&2
  echo "versions currently in Standard Support, then pass --version=X.Y." >&2
  exit 1
fi

# 2. Extract the requested version (support --version 1.33 and --version=1.33)
VERSION=$(printf '%s\n' "$@" | awk '
  /^--version=/ { split($0,a,"="); print a[2]; exit }
  prev=="--version" { print; exit }
  { prev=$0 }
')

if [ -z "${VERSION:-}" ]; then
  echo "ERROR: --version flag present but value not parsed." >&2
  exit 1
fi

# 3. Check that version is in Standard Support
echo "Checking EKS lifecycle state for Kubernetes $VERSION..."
SUPPORT=$(aws eks describe-cluster-versions \
  --cluster-type eks \
  --query "clusterVersions[?clusterVersion==\`$VERSION\`].versionStatus | [0]" \
  --output text 2>/dev/null || echo "UNKNOWN")

case "$SUPPORT" in
  STANDARD_SUPPORT)
    echo "OK: Kubernetes $VERSION is in Standard Support (control plane \$0.10/hr)."
    ;;
  EXTENDED_SUPPORT)
    echo "REFUSED: Kubernetes $VERSION is in Extended Support." >&2
    echo "Control plane would cost \$0.60/hr (\$0.10 Standard + \$0.50 penalty)." >&2
    echo "Pick a version in STANDARD_SUPPORT from:" >&2
    aws eks describe-cluster-versions --cluster-type eks \
      --query "clusterVersions[?versionStatus=='STANDARD_SUPPORT'].clusterVersion" \
      --output text >&2
    exit 2
    ;;
  UNSUPPORTED)
    echo "REFUSED: Kubernetes $VERSION is no longer supported on EKS." >&2
    exit 2
    ;;
  UNKNOWN|"")
    echo "WARN: Could not determine lifecycle state for $VERSION." >&2
    echo "Proceed only if you have manually verified the version is in" >&2
    echo "Standard Support. Press Ctrl+C to abort, Enter to proceed." >&2
    read -r _
    ;;
  *)
    echo "REFUSED: Unexpected lifecycle state '$SUPPORT' for $VERSION." >&2
    exit 2
    ;;
esac

# 4. Hand off to eksctl with all original args
echo "Running: eksctl create cluster $*"
exec eksctl create cluster "$@"
