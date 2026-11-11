terraform {
  required_version = ">= 1.9.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.14"
    }
    # aws_bcmdataexports_export landed in v5.42 (March 2024); pinning
    # to the ~> 5.80 window keeps that resource available while leaving
    # room for backward-compatible patches.
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.80"
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

# All AWS Billing APIs (Data Exports, Cost Explorer, CUR 2.0) are
# us-east-1-only as of 2026, so pinning the provider there is not a
# preference - it is a hard requirement of the service.
provider "aws" {
  region = var.aws_region
}
