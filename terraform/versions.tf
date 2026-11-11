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
    # azurerm_subscription_cost_management_export stable since v3.70;
    # azurerm v4.x line is current, carries Cost Management + Storage
    # with the expected API surface.
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    # azuread for App Registration + Service Principal + client secret
    # on the Grafana reader. These sit on Microsoft Graph, not the ARM
    # plane that azurerm covers, so it is a separate provider.
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.0"
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

provider "azurerm" {
  features {}
  subscription_id = var.azure_subscription_id
  tenant_id       = var.azure_tenant_id
}

provider "azuread" {
  tenant_id = var.azure_tenant_id
}
