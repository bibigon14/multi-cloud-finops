#!/usr/bin/env bash
#
# Cross-cloud billing audit - scans GCP + AWS + Azure + OCI for resources
# that cost money without an active workload. Run after tearing down a demo
# stack to confirm no NAT Gateway, unattached Elastic IP, orphan disk or
# static Public IP is left billing.
#
# No writes, no deletes - read-only listings. Takes ~30-60s depending on
# how many regions each CLI probes.

set +e  # a single sub-command failing shouldn't stop the audit

echo "============================================================"
echo "CROSS-CLOUD BILLING AUDIT - $(date)"
echo "============================================================"

echo
echo "### GCP ###"
gcloud config get-value project
echo "-- Compute instances --"
gcloud compute instances list 2>&1 | head -20
echo "-- GKE clusters --"
gcloud container clusters list 2>&1 | head -10
echo "-- Persistent disks (orphan \$0.04/GB-mo) --"
gcloud compute disks list --filter="-users:*" --format="table(name,zone,sizeGb,status)" 2>&1 | head -20
echo "-- Static IPs (unused IP = \$0.005/hr ~ \$3.65/mo) --"
gcloud compute addresses list --filter="status:RESERVED" 2>&1 | head -10
echo "-- Load balancers --"
gcloud compute forwarding-rules list 2>&1 | head -10
echo "-- Cloud SQL --"
gcloud sql instances list 2>&1 | head -10
echo "-- GCS buckets --"
gcloud storage buckets list --format="value(name)" 2>&1 | head -20

echo
echo "### AWS us-east-1 ###"
echo "-- EC2 instances --"
aws ec2 describe-instances --region us-east-1 \
  --query 'Reservations[].Instances[?State.Name!=`terminated`].[InstanceId,InstanceType,State.Name,Tags[?Key==`Name`].Value|[0]]' \
  --output table 2>&1 | head -20
echo "-- EKS clusters --"
aws eks list-clusters --region us-east-1 2>&1
echo "-- NAT Gateways (\$0.045/hr each ~ \$33/mo!) --"
aws ec2 describe-nat-gateways --region us-east-1 \
  --filter 'Name=state,Values=available,pending' \
  --query 'NatGateways[].[NatGatewayId,State,VpcId]' \
  --output table 2>&1 | head -20
echo "-- Elastic IPs (unattached = \$0.005/hr) --"
aws ec2 describe-addresses --region us-east-1 \
  --query 'Addresses[?!AssociationId].[AllocationId,PublicIp]' \
  --output table 2>&1 | head -20
echo "-- Load balancers (ALB/NLB \$0.0225/hr each) --"
aws elbv2 describe-load-balancers --region us-east-1 \
  --query 'LoadBalancers[].[LoadBalancerName,Type,State.Code]' \
  --output table 2>&1 | head -20
echo "-- EBS volumes unattached (\$0.08/GB-mo) --"
aws ec2 describe-volumes --region us-east-1 \
  --filters Name=status,Values=available \
  --query 'Volumes[].[VolumeId,Size,VolumeType,CreateTime]' \
  --output table 2>&1 | head -20
echo "-- RDS instances --"
aws rds describe-db-instances --region us-east-1 \
  --query 'DBInstances[].[DBInstanceIdentifier,DBInstanceStatus]' \
  --output table 2>&1 | head -10
echo "-- VPCs (default + custom) --"
aws ec2 describe-vpcs --region us-east-1 \
  --query 'Vpcs[].[VpcId,CidrBlock,IsDefault]' --output table 2>&1 | head -20
echo "-- Sanity check other regions --"
for region in us-west-2 eu-west-1; do
  echo "   $region EKS: $(aws eks list-clusters --region "$region" --query 'clusters' --output text 2>&1)"
  echo "   $region EC2 running: $(aws ec2 describe-instances --region "$region" \
    --query 'Reservations[].Instances[?State.Name==`running`].InstanceId' --output text 2>&1 | wc -w)"
done

echo
echo "### Azure ###"
echo "-- VMs --"
az vm list --output table 2>&1 | head -20
echo "-- AKS clusters --"
az aks list --output table 2>&1 | head -10
echo "-- Public IPs (static \$0.004/hr ~ \$3/mo even if unassigned) --"
az network public-ip list --output table 2>&1 | head -20
echo "-- Load balancers --"
az network lb list --output table 2>&1 | head -10
echo "-- Resource groups --"
az group list --output table 2>&1 | head -20
echo "-- Storage accounts --"
az storage account list --output table 2>&1 | head -10

echo
echo "### OCI (Always Free sanity) ###"
COMPARTMENT=$(oci iam compartment list --all --query 'data[0].id' --raw-output 2>/dev/null)
if [ -n "$COMPARTMENT" ]; then
  echo "-- Compute instances (Always Free shapes only expected) --"
  oci compute instance list --compartment-id "$COMPARTMENT" \
    --query 'data[].{name:"display-name", shape:shape, state:"lifecycle-state"}' --output table 2>&1 | head -10
else
  echo "   oci CLI not configured or compartment lookup failed"
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
