# Azure Cost Management Export + Grafana reader App Registration.
#
# Three services in one file, same pattern as aws.tf:
#   1) Storage Account + Blob container as the export sink.
#   2) Cost Management Export writing daily Actual Cost data to that
#      container. Azure's Cost Management runs at subscription scope, so
#      the export resource targets the subscription directly.
#   3) Azure AD App Registration + Service Principal + scoped role
#      assignments for Grafana's Infinity datasource to call the Cost
#      Management REST API over OAuth2 client credentials.
#
# The Infinity datasource reads Cost Management API responses in
# near-real-time (1-2 hour lag) rather than waiting on daily exports,
# so the dashboard panels light up the same day the SP is wired. The
# exported blobs are kept for v0.5 FOCUS federation work across clouds.

# ---------------------------------------------------------------------------
# Resource group.
# ---------------------------------------------------------------------------

resource "azurerm_resource_group" "finops" {
  name     = var.azure_resource_group
  location = var.azure_location
  tags = {
    Project = "multi-cloud-finops"
    Purpose = "Cost Management export + Grafana reader"
  }
}

# ---------------------------------------------------------------------------
# Storage account + container for Cost Management exports.
# ---------------------------------------------------------------------------
#
# Azure storage account names must be globally unique, lowercase
# alphanumeric only, 3-24 characters. The naming here follows the same
# dstepanov-* pattern as the GCS and S3 buckets in sibling files.

resource "azurerm_storage_account" "cost_export" {
  name                     = var.azure_storage_account_name
  resource_group_name      = azurerm_resource_group.finops.name
  location                 = azurerm_resource_group.finops.location
  account_tier             = "Standard"
  account_replication_type = "LRS"

  # No public access, no cross-origin reads, HTTPS only. Blob files
  # hold account-level billing detail; the CUR bucket next door has
  # the same posture.
  allow_nested_items_to_be_public = false
  public_network_access_enabled   = true
  https_traffic_only_enabled      = true
  min_tls_version                 = "TLS1_2"

  blob_properties {
    # Cost Management rewrites the current-month export on every
    # refresh; 90-day retention on the delete queue lets us recover
    # from an accidental overwrite without paying for versioning.
    delete_retention_policy {
      days = 90
    }
  }

  tags = {
    Project = "multi-cloud-finops"
    Purpose = "Azure Cost Management export sink"
  }
}

resource "azurerm_storage_container" "cost_export" {
  name                  = "cost-export"
  storage_account_id    = azurerm_storage_account.cost_export.id
  container_access_type = "private"
}

# ---------------------------------------------------------------------------
# Subscription-scoped Cost Management Export (daily Actual Cost).
# ---------------------------------------------------------------------------
#
# Azure Cost Management can target billing account, subscription, RG,
# department, or enrollment account. Subscription scope catches every
# resource in the subscription, which is what a FinOps dashboard wants.
#
# time_frame = MonthToDate: the export always writes the current month's
# running total on each refresh, which is the shape the Grafana MTD and
# burn-rate panels query. Historical months stay in the container as
# separate blobs the v0.5 FOCUS cross-cloud query will join against.

resource "azurerm_subscription_cost_management_export" "finops" {
  name                         = var.azure_cost_export_name
  subscription_id              = "/subscriptions/${var.azure_subscription_id}"
  recurrence_type              = "Daily"
  recurrence_period_start_date = "${formatdate("YYYY-MM-DD", timestamp())}T00:00:00Z"
  recurrence_period_end_date   = "${formatdate("YYYY", timeadd(timestamp(), "26280h"))}-12-31T23:59:59Z"

  export_data_storage_location {
    container_id     = azurerm_storage_container.cost_export.resource_manager_id
    root_folder_path = "exports"
  }

  export_data_options {
    type       = "ActualCost"
    time_frame = "MonthToDate"
  }

  # timestamp() returns a different value on each plan, so the recurrence
  # fields otherwise redrive the export every apply. Pin them.
  lifecycle {
    ignore_changes = [
      recurrence_period_start_date,
      recurrence_period_end_date,
    ]
  }
}

# ---------------------------------------------------------------------------
# Grafana reader: Azure AD App Registration + Service Principal.
# ---------------------------------------------------------------------------
#
# The Infinity datasource authenticates to the ARM Cost Management API
# via OAuth2 client credentials (tenant + client id + secret). That
# needs a registered App + a Service Principal + a role assignment.
#
# No Microsoft Graph permissions are granted - this SP is read-only on
# billing data, nothing else. The scope is kept at the subscription so
# a future subscription-level cost query (Microsoft.CostManagement/query
# is a subscription-level action) can call it, but the only RBAC role
# assigned is Cost Management Reader - no read access to any resource
# data, only to billing queries.

resource "azuread_application" "grafana" {
  display_name = var.azure_app_name
  description  = "Grafana Infinity datasource reader for Cost Management API (multi-cloud-finops)"
}

resource "azuread_service_principal" "grafana" {
  client_id                    = azuread_application.grafana.client_id
  app_role_assignment_required = false
}

resource "azuread_application_password" "grafana" {
  application_id = azuread_application.grafana.id
  display_name   = "grafana-infinity-datasource"
  end_date       = formatdate("YYYY-MM-DD'T'hh:mm:ss'Z'", timeadd(timestamp(), "8760h")) # 1 year

  lifecycle {
    ignore_changes = [end_date]
  }
}

# Cost Management Reader: can call Microsoft.CostManagement/query on
# the subscription, nothing else. This is the narrowest built-in role
# that covers the Cost Management API surface Grafana needs.
resource "azurerm_role_assignment" "grafana_cost_reader" {
  scope                = "/subscriptions/${var.azure_subscription_id}"
  role_definition_name = "Cost Management Reader"
  principal_id         = azuread_service_principal.grafana.object_id
}

# Blob Data Reader on the cost export container: lets Grafana (or a
# future reporting job) read the exported blobs directly for FOCUS 1.0
# cross-cloud queries in v0.5. No role on the storage account itself,
# so the SP cannot list other containers or read account metadata.
resource "azurerm_role_assignment" "grafana_blob_reader" {
  scope                = azurerm_storage_container.cost_export.resource_manager_id
  role_definition_name = "Storage Blob Data Reader"
  principal_id         = azuread_service_principal.grafana.object_id
}
