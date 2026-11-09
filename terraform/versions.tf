terraform {
  required_version = ">= 1.9.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.14"
    }
  }

  # GCS backend lives alongside the state for the other dstepanov-*
  # GCP projects. One bucket, one project per state key.
  backend "gcs" {
    bucket = "dstepanov-tfstate-gke"
    prefix = "multi-cloud-finops"
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}
