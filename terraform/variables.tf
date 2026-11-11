variable "project_id" {
  type        = string
  description = "GCP project that holds the BQ dataset and the Grafana service account"
  default     = "dstepanov-gke-platform"
}

variable "region" {
  type        = string
  description = "Default region for provider calls (dataset itself is multi-region US)"
  default     = "us-west1"
}

variable "billing_account_id" {
  type        = string
  description = "Cloud Billing account that feeds the BigQuery export, dashes preserved"
  default     = "0108CD-97A262-B94181"
}

variable "billing_dataset" {
  type        = string
  description = "BigQuery dataset where Standard and Detailed billing exports land"
  default     = "billing_export"
}

variable "grafana_sa_name" {
  type        = string
  description = "Short name of the service account Grafana uses to read the billing dataset"
  default     = "grafana-bq-reader"
}

# ---------------------------------------------------------------------------
# AWS (v0.2 additions)
# ---------------------------------------------------------------------------

variable "aws_account_id" {
  type        = string
  description = "AWS account ID that owns the CUR bucket and the Grafana IAM user"
  default     = "493539461415"
}

variable "aws_region" {
  type        = string
  description = "AWS region for every resource in aws.tf - must be us-east-1 because the Billing APIs run only there"
  default     = "us-east-1"
}

variable "cur_bucket_name" {
  type        = string
  description = "Globally-unique S3 bucket that receives CUR 2.0 parquet exports. The Athena results bucket is <this>-athena-results"
  default     = "dstepanov-aws-cur-export"
}

variable "cur_s3_prefix" {
  type        = string
  description = "S3 key prefix under cur_bucket_name - the Billing service lays out <prefix>/<export_name>/data/BILLING_PERIOD=YYYY-MM/"
  default     = "cur2"
}

variable "cur_export_name" {
  type        = string
  description = "Name of the CUR 2.0 export resource in AWS Data Exports (also becomes the Glue table name once the crawler runs)"
  default     = "multi-cloud-finops-cur2"
}

variable "athena_workgroup_name" {
  type        = string
  description = "Athena workgroup that isolates Grafana query runs and enforces the 10 GiB per-query scan cap"
  default     = "multi-cloud-finops"
}

variable "glue_database_name" {
  type        = string
  description = "Glue catalog database the crawler writes the CUR 2.0 table into"
  default     = "multi_cloud_finops"
}

variable "grafana_iam_user_name" {
  type        = string
  description = "IAM user with Athena read rights that Grafana's Athena datasource authenticates as"
  default     = "grafana-athena-reader"
}

# ---------------------------------------------------------------------------
# Azure (v0.3 additions)
# ---------------------------------------------------------------------------

variable "azure_subscription_id" {
  type        = string
  description = "Azure subscription that owns the Cost Management export and the Grafana reader SP"
  default     = "c395c797-0fbf-40e6-b1f8-b9a1eee8d838"
}

variable "azure_tenant_id" {
  type        = string
  description = "Entra ID tenant that hosts the Grafana App Registration and the subscription above"
  default     = "b0c15b86-1306-4962-ad60-97937c9692cb"
}

variable "azure_location" {
  type        = string
  description = "Azure region for the FinOps resource group - storage pinned here, but Cost Management runs at subscription scope independent of location"
  default     = "eastus"
}

variable "azure_resource_group" {
  type        = string
  description = "Resource group that holds the Cost Management export storage account and container; separate from the finops-demo-rg that holds the short-lived AKS workload"
  default     = "multi-cloud-finops-rg"
}

variable "azure_storage_account_name" {
  type        = string
  description = "Globally-unique Azure storage account for the Cost Management export; must be 3-24 lowercase alphanumeric characters"
  default     = "dstepanovmcfcostexp"
}

variable "azure_cost_export_name" {
  type        = string
  description = "Name of the subscription-scoped Cost Management export that writes daily Actual Cost blobs to the storage container"
  default     = "multi-cloud-finops-cost-export"
}

variable "azure_app_name" {
  type        = string
  description = "Display name of the Azure AD App Registration that Grafana's Infinity datasource authenticates as"
  default     = "grafana-cost-reader"
}
