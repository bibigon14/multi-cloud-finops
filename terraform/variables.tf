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
