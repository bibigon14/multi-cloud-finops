# The billing_export dataset itself is managed by the Cloud Billing
# console (it must exist BEFORE the BQ export is enabled, and Terraform
# cannot create the export sink itself - there is no first-class GCP
# resource for it as of 2026). This data block pins the dataset so a
# plan fails fast if the dataset is deleted out-of-band.
data "google_bigquery_dataset" "billing_export" {
  dataset_id = var.billing_dataset
  project    = var.project_id
}

# Service account Grafana uses to read the billing tables via the
# BigQuery datasource plugin. Key material is generated separately
# and kept out of state.
resource "google_service_account" "grafana_bq_reader" {
  account_id   = var.grafana_sa_name
  display_name = "Grafana BigQuery reader (multi-cloud-finops)"
  description  = "Read-only access to the billing_export dataset for Grafana dashboards"
}

# Dataset-level read. Narrower than project-level BQ user: this SA can
# query tables in billing_export but cannot create datasets, jobs
# elsewhere, or read any other data in the project.
resource "google_bigquery_dataset_iam_member" "grafana_viewer" {
  dataset_id = data.google_bigquery_dataset.billing_export.dataset_id
  project    = var.project_id
  role       = "roles/bigquery.dataViewer"
  member     = "serviceAccount:${google_service_account.grafana_bq_reader.email}"
}

# BQ jobs run in a project (not the dataset) so the SA also needs the
# right to start jobs in this project. Without it, Grafana gets
# PERMISSION_DENIED on the first SELECT even though data access is fine.
resource "google_project_iam_member" "grafana_job_user" {
  project = var.project_id
  role    = "roles/bigquery.jobUser"
  member  = "serviceAccount:${google_service_account.grafana_bq_reader.email}"
}
