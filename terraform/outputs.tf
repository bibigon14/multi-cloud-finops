output "billing_export_dataset" {
  value       = data.google_bigquery_dataset.billing_export.id
  description = "Fully-qualified BQ dataset ID (project:dataset) for the billing export"
}

output "grafana_sa_email" {
  value       = google_service_account.grafana_bq_reader.email
  description = "Service account email - use when generating a key for Grafana"
}

# Convenience hint for the follow-up command the user runs manually
# once Terraform has provisioned the SA. Printed, not executed - the
# key material should never land in state.
output "grafana_key_create_hint" {
  value = <<-EOT
    # Generate a JSON key for Grafana once (store it in Grafana's secret manager, not here):
    gcloud iam service-accounts keys create grafana-bq-reader.json \
      --iam-account=${google_service_account.grafana_bq_reader.email}
  EOT
}

# ---------------------------------------------------------------------------
# AWS (v0.2 additions)
# ---------------------------------------------------------------------------

output "aws_cur_bucket" {
  value       = aws_s3_bucket.cur.bucket
  description = "S3 bucket CUR 2.0 writes parquet exports into"
}

output "aws_athena_results_bucket" {
  value       = aws_s3_bucket.athena_results.bucket
  description = "S3 bucket Athena stages query results into (7-day expiry)"
}

output "aws_athena_workgroup" {
  value       = aws_athena_workgroup.finops.name
  description = "Athena workgroup name - plug this into the Grafana Athena datasource"
}

output "aws_glue_database" {
  value       = aws_glue_catalog_database.cur.name
  description = "Glue database name - plug this into the Grafana Athena datasource"
}

output "grafana_aws_access_key_id" {
  value       = aws_iam_access_key.grafana.id
  description = "Access key id for the Grafana IAM user - goes into the datasource provisioning file (not secret, but kept out of git)"
}

output "grafana_aws_secret_key" {
  value       = aws_iam_access_key.grafana.secret
  description = "Secret key for the Grafana IAM user - fetch with `terraform output -raw grafana_aws_secret_key`, paste into Grafana secret store, then wipe scrollback"
  sensitive   = true
}

output "grafana_aws_setup_hint" {
  value = <<-EOT
    # Pull the Grafana AWS credentials and the Athena wiring out of state:
    terraform output -raw grafana_aws_access_key_id
    terraform output -raw grafana_aws_secret_key   # paste into Grafana secret store
    terraform output -raw aws_athena_workgroup     # multi-cloud-finops
    terraform output -raw aws_glue_database        # multi_cloud_finops
    terraform output -raw aws_athena_results_bucket  # s3://.../results/
  EOT
}
