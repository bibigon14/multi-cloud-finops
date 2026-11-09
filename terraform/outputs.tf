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
