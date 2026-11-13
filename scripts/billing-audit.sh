#!/usr/bin/env bash
#
# Cross-cloud billing audit - scans GCP + AWS + Azure + OCI for resources
# that cost money without an active workload. Run after tearing down a demo
# stack to confirm no NAT Gateway, unattached Elastic IP, orphan disk or
# static Public IP is left billing.
#
# No writes, no deletes - read-only listings. Each sub-command runs under
# `timeout 15s` so a hanging CLI (eg an API not yet enabled in the project)
# does not block the whole audit.

set +e  # a single sub-command failing shouldn't stop the audit

RUN() {
  # run with a 15s wall-clock cap; on timeout print a terse marker
  timeout 15s "$@" 2>&1
  local rc=$?
  if [ $rc -eq 124 ]; then
    echo "   [TIMEOUT after 15s - skipping]"
  fi
}

echo "============================================================"
echo "CROSS-CLOUD BILLING AUDIT - $(date)"
echo "============================================================"

echo
echo "### GCP ###"
RUN gcloud config get-value project
echo "-- Compute instances --"
RUN gcloud compute instances list | head -20
echo "-- GKE clusters --"
RUN gcloud container clusters list | head -10
echo "-- Persistent disks (orphan \$0.04/GB-mo) --"
RUN gcloud compute disks list --filter="-users:*" --format="table(name,zone,sizeGb,status)" | head -20
echo "-- Static IPs (RESERVED but not IN_USE = \$0.005/hr ~ \$3.65/mo) --"
RUN gcloud compute addresses list --filter="status:RESERVED" | head -10
echo "-- Load balancers --"
RUN gcloud compute forwarding-rules list | head -10
echo "-- Cloud SQL (may be slow if SQL Admin API not enabled) --"
RUN gcloud sql instances list | head -10
echo "-- GCS buckets --"
RUN gcloud storage buckets list --format="value(name)" | head -20

echo
echo "### AWS us-east-1 ###"
echo "-- EC2 instances --"
RUN aws ec2 describe-instances --region us-east-1 \
  --query 'Reservations[].Instances[?State.Name!=`terminated`].[InstanceId,InstanceType,State.Name,Tags[?Key==`Name`].Value|[0]]' \
  --output table | head -20
echo "-- EKS clusters --"
RUN aws eks list-clusters --region us-east-1
echo "-- NAT Gateways (\$0.045/hr each ~ \$33/mo!) --"
RUN aws ec2 describe-nat-gateways --region us-east-1 \
  --filter 'Name=state,Values=available,pending' \
  --query 'NatGateways[].[NatGatewayId,State,VpcId]' --output table | head -20
echo "-- Elastic IPs (unattached = \$0.005/hr) --"
RUN aws ec2 describe-addresses --region us-east-1 \
  --query 'Addresses[?!AssociationId].[AllocationId,PublicIp]' --output table | head -20
echo "-- Load balancers (ALB/NLB \$0.0225/hr each) --"
RUN aws elbv2 describe-load-balancers --region us-east-1 \
  --query 'LoadBalancers[].[LoadBalancerName,Type,State.Code]' --output table | head -20
echo "-- EBS volumes unattached (\$0.08/GB-mo) --"
RUN aws ec2 describe-volumes --region us-east-1 \
  --filters Name=status,Values=available \
  --query 'Volumes[].[VolumeId,Size,VolumeType,CreateTime]' --output table | head -20
echo "-- RDS instances --"
RUN aws rds describe-db-instances --region us-east-1 \
  --query 'DBInstances[].[DBInstanceIdentifier,DBInstanceStatus]' --output table | head -10
echo "-- VPCs (default + custom) --"
RUN aws ec2 describe-vpcs --region us-east-1 \
  --query 'Vpcs[].[VpcId,CidrBlock,IsDefault]' --output table | head -20
echo "-- Sanity check other regions --"
for region in us-west-2 eu-west-1; do
  echo -n "   $region EKS: "
  RUN aws eks list-clusters --region "$region" --query 'clusters' --output text
  echo -n "   $region running EC2: "
  RUN aws ec2 describe-instances --region "$region" \
    --query 'Reservations[].Instances[?State.Name==`running`].InstanceId' --output text | wc -w
done

echo
echo "### Azure ###"
echo "-- VMs --"
RUN az vm list --output table | head -20
echo "-- AKS clusters --"
RUN az aks list --output table | head -10
echo "-- Public IPs (static \$0.004/hr ~ \$3/mo even if unassigned) --"
RUN az network public-ip list --output table | head -20
echo "-- Load balancers --"
RUN az network lb list --output table | head -10
echo "-- Resource groups --"
RUN az group list --output table | head -20
echo "-- Storage accounts --"
RUN az storage account list --output table | head -10

echo
echo "### OCI (Always Free sanity) ###"
COMPARTMENT=$(timeout 10s oci iam compartment list --all --query 'data[0].id' --raw-output 2>/dev/null)
if [ -n "$COMPARTMENT" ]; then
  echo "-- Compute instances (Always Free shapes only expected) --"
  RUN oci compute instance list --compartment-id "$COMPARTMENT" \
    --query 'data[].{name:"display-name", shape:shape, state:"lifecycle-state"}' --output table | head -10
else
  echo "   oci CLI not configured or compartment lookup failed/timed-out"
fi

echo
echo "### Cloudflare ###"
echo "   Workers Paid is flat \$5/month - no scaling cost."
echo "   Spot-check via dash: https://dash.cloudflare.com/?account=analytics"

echo
echo "============================================================"
echo "AUDIT DONE - $(date)"
echo
echo "Kill-if-found, biggest-spend-first:"
echo "  AWS  NAT Gateway        ~\$33/mo each"
echo "  AWS  ALB/NLB            ~\$16/mo each"
echo "  AWS  Unattached EIP     ~\$3.65/mo each"
echo "  GCP  Reserved static IP ~\$3.65/mo each (RESERVED, not IN_USE)"
echo "  Azure Static Public IP  ~\$3/mo each"
echo "  Any  Orphan disks/volumes - varies by size"
echo "============================================================"
