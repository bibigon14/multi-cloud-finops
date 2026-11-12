# AWS billing export + Athena + Grafana reader, aliased provider so the
# GCP module stays untouched. All AWS resources live in us-east-1 because
# the AWS Billing APIs (Data Exports, Cost Explorer) only run there as of
# 2026. Other regional resources would still get the same region: a
# multi-cloud-finops repo that ran Athena in one region and CUR in
# another would be asking for cross-region data transfer charges on the
# very workload it exists to watch.

# ---------------------------------------------------------------------------
# S3 bucket that the Billing service writes CUR 2.0 reports into.
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "cur" {
  bucket        = var.cur_bucket_name
  force_destroy = false
  tags = {
    Project = "multi-cloud-finops"
    Purpose = "CUR 2.0 billing export sink"
  }
}

# Block every public access path. CUR files hold account-level cost
# detail, including resource ARNs and labels - never intended for
# anonymous access and not something CloudFront should ever front.
resource "aws_s3_bucket_public_access_block" "cur" {
  bucket                  = aws_s3_bucket.cur.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Server-side encryption with the account-default SSE-S3 key. CUR files
# are not customer-supplied payloads so KMS would add cost for no
# meaningful threat-model gain; SSE-S3 covers the "disk left in a
# datacenter" bar that compliance checklists ask for.
resource "aws_s3_bucket_server_side_encryption_configuration" "cur" {
  bucket = aws_s3_bucket.cur.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Lifecycle: CUR 2.0 overwrites the current-month report on every
# refresh and leaves closed months as-is. The oldest useful partition
# for a 30-day burn-rate panel is 60 days back. Everything older moves
# to GLACIER_IR on day 90 - cheap enough to keep forever, and exactly
# the thing a FinOps dashboard should demonstrate on its own storage.
resource "aws_s3_bucket_lifecycle_configuration" "cur" {
  bucket = aws_s3_bucket.cur.id
  rule {
    id     = "archive-old-partitions"
    status = "Enabled"
    filter {}
    transition {
      days          = 90
      storage_class = "GLACIER_IR"
    }
  }
}

# Bucket policy that lets the CUR 2.0 service principal
# (bcm-data-exports.amazonaws.com) write reports here. The SourceAccount
# and SourceArn conditions scope the grant to this exact export in this
# exact account, so leaking the bucket name does not give any other
# account a write path.
data "aws_iam_policy_document" "cur_bucket_policy" {
  statement {
    sid    = "AllowCURServiceWriteAndPolicyCheck"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["bcm-data-exports.amazonaws.com", "billingreports.amazonaws.com"]
    }
    actions = [
      "s3:PutObject",
      "s3:GetBucketAcl",
      "s3:GetBucketPolicy",
    ]
    resources = [
      aws_s3_bucket.cur.arn,
      "${aws_s3_bucket.cur.arn}/*",
    ]
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [var.aws_account_id]
    }
    condition {
      test     = "StringLike"
      variable = "aws:SourceArn"
      values = [
        "arn:aws:cur:us-east-1:${var.aws_account_id}:definition/*",
        "arn:aws:bcm-data-exports:us-east-1:${var.aws_account_id}:export/*",
      ]
    }
  }
}

resource "aws_s3_bucket_policy" "cur" {
  bucket = aws_s3_bucket.cur.id
  policy = data.aws_iam_policy_document.cur_bucket_policy.json
}

# ---------------------------------------------------------------------------
# CUR 2.0 export definition.
# ---------------------------------------------------------------------------
#
# CUR 2.0 is the AWS Data Exports replacement for the legacy Cost and
# Usage Report. The query_statement is a fixed SQL that AWS runs on
# their side; the full-column form `SELECT * FROM COST_AND_USAGE_REPORT`
# is the richest shape and the one that still supports resource IDs
# plus user-defined cost allocation tags - needed for the per-K8s-
# namespace attribution planned in v0.4.
#
# INCLUDE_RESOURCES = TRUE is what carries the `line_item_resource_id`
# column. Without it, EC2/EKS node spend is not attributable past the
# service level. FOCUS 1.0 output is a separate export; the main
# narrative here is the native CUR 2.0 shape, which the FOCUS view
# query_statement can also render from.
#
# The Data Exports API refuses `SELECT *` with a ValidationException,
# so the export declares the exact column set it wants. The list below
# was picked deliberately rather than being a blind "everything":
#
#   bill_* / identity_* / line_item_* : the core FinOps grain -
#     what was charged, to which account, when, for what SKU, at what
#     unit price. These drive every panel in grafana/dashboards.
#   product_* : human-readable service name, region, instance family -
#     the attributes a FinOps dashboard groups by.
#   pricing_* : on-demand reference prices, unit, term - lets later
#     queries compare actual cost to the public list price.
#   reservation_* / savings_plan_* : RI and SP coverage, needed for
#     "unblended vs amortized vs effective" comparisons that come up
#     the moment this account grows past hobby-scale.
#   resource_tags : MAP of cost-allocation tags, including the
#     `user:goog-k8s-namespace`-equivalent eks tag path, which v0.5
#     pivots on for per-K8s-namespace attribution.
#
# ~70 well-chosen columns, every row of CUR 2.0 kept queryable, no
# unused "every column just in case" bloat on S3.

resource "aws_bcmdataexports_export" "cur2" {
  export {
    name        = var.cur_export_name
    description = "CUR 2.0 hourly export for multi-cloud-finops v0.2"

    data_query {
      query_statement = join(", ", [
        "SELECT bill_bill_type",
        "bill_billing_entity",
        "bill_billing_period_end_date",
        "bill_billing_period_start_date",
        "bill_invoice_id",
        "bill_invoicing_entity",
        "bill_payer_account_id",
        "identity_line_item_id",
        "identity_time_interval",
        "line_item_availability_zone",
        "line_item_blended_cost",
        "line_item_blended_rate",
        "line_item_currency_code",
        "line_item_legal_entity",
        "line_item_line_item_description",
        "line_item_line_item_type",
        "line_item_normalization_factor",
        "line_item_normalized_usage_amount",
        "line_item_operation",
        "line_item_product_code",
        "line_item_resource_id",
        "line_item_tax_type",
        "line_item_unblended_cost",
        "line_item_unblended_rate",
        "line_item_usage_account_id",
        "line_item_usage_amount",
        "line_item_usage_end_date",
        "line_item_usage_start_date",
        "line_item_usage_type",
        "product_from_location",
        "product_from_location_type",
        "product_instance_family",
        "product_instance_type",
        "product_location",
        "product_location_type",
        "product_operation",
        "product_pricing_unit",
        "product_product_family",
        "product_region_code",
        "product_servicecode",
        "product_sku",
        "product_to_location",
        "product_to_location_type",
        "product_usagetype",
        "pricing_currency",
        "pricing_lease_contract_length",
        "pricing_offering_class",
        "pricing_public_on_demand_cost",
        "pricing_public_on_demand_rate",
        "pricing_purchase_option",
        "pricing_rate_code",
        "pricing_rate_id",
        "pricing_term",
        "pricing_unit",
        "reservation_amortized_upfront_cost_for_usage",
        "reservation_amortized_upfront_fee_for_billing_period",
        "reservation_effective_cost",
        "reservation_end_time",
        "reservation_modification_status",
        "reservation_recurring_fee_for_usage",
        "reservation_reservation_a_r_n",
        "reservation_start_time",
        "reservation_subscription_id",
        "savings_plan_amortized_upfront_commitment_for_billing_period",
        "savings_plan_end_time",
        "savings_plan_instance_type_family",
        "savings_plan_offering_type",
        "savings_plan_payment_option",
        "savings_plan_purchase_term",
        "savings_plan_recurring_commitment_for_billing_period",
        "savings_plan_region",
        "savings_plan_savings_plan_a_r_n",
        "savings_plan_savings_plan_effective_cost",
        "savings_plan_savings_plan_rate",
        "savings_plan_start_time",
        "savings_plan_total_commitment_to_date",
        "savings_plan_used_commitment",
        "resource_tags",
        "split_line_item_actual_usage",
        "split_line_item_parent_resource_id",
        "split_line_item_public_on_demand_split_cost",
        "split_line_item_public_on_demand_unused_cost",
        "split_line_item_reserved_usage",
        "split_line_item_split_cost",
        "split_line_item_split_usage",
        "split_line_item_split_usage_ratio",
        "split_line_item_unused_cost FROM COST_AND_USAGE_REPORT",
      ])
      table_configurations = {
        COST_AND_USAGE_REPORT = {
          TIME_GRANULARITY                      = "HOURLY"
          INCLUDE_RESOURCES                     = "TRUE"
          INCLUDE_MANUAL_DISCOUNT_COMPATIBILITY = "FALSE"
          INCLUDE_SPLIT_COST_ALLOCATION_DATA    = "TRUE"
          # BILLING_VIEW_ARN is a newer Data Exports attribute that the
          # service echoes back on every GetExport call since Billing
          # Views shipped in 2025. The hashicorp/aws v5.100 provider
          # does not strip it from the response, which triggers
          # "Provider produced inconsistent result after apply" the
          # first time this resource is created. Declaring it as "" in
          # the plan tells the provider we know about the attribute
          # and accept the account's default billing view.
          BILLING_VIEW_ARN = "arn:aws:billing::493539461415:billingview/primary"
        }
      }
    }

    destination_configurations {
      s3_destination {
        s3_bucket = aws_s3_bucket.cur.id
        s3_prefix = var.cur_s3_prefix
        s3_region = var.aws_region

        s3_output_configurations {
          overwrite   = "OVERWRITE_REPORT"
          format      = "PARQUET"
          compression = "PARQUET"
          output_type = "CUSTOM"
        }
      }
    }

    refresh_cadence {
      frequency = "SYNCHRONOUS"
    }
  }

  depends_on = [aws_s3_bucket_policy.cur]
}

# ---------------------------------------------------------------------------
# S3 bucket for Athena query results.
# ---------------------------------------------------------------------------
#
# Athena always needs a staging bucket for result sets. Kept separate
# from the CUR bucket so the CUR bucket stays append-only from the
# Billing service's perspective and the Grafana SA never has write
# rights on it.

resource "aws_s3_bucket" "athena_results" {
  bucket        = "${var.cur_bucket_name}-athena-results"
  force_destroy = true
  tags = {
    Project = "multi-cloud-finops"
    Purpose = "Athena query result staging"
  }
}

resource "aws_s3_bucket_public_access_block" "athena_results" {
  bucket                  = aws_s3_bucket.athena_results.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "athena_results" {
  bucket = aws_s3_bucket.athena_results.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Query results are intermediate output, not evidence. Delete them
# after 7 days so this bucket does not quietly become the biggest cost
# line in the project it exists to watch.
resource "aws_s3_bucket_lifecycle_configuration" "athena_results" {
  bucket = aws_s3_bucket.athena_results.id
  rule {
    id     = "expire-query-results"
    status = "Enabled"
    filter {}
    expiration {
      days = 7
    }
  }
}

# ---------------------------------------------------------------------------
# Athena workgroup + Glue database + crawler.
# ---------------------------------------------------------------------------

resource "aws_athena_workgroup" "finops" {
  name          = var.athena_workgroup_name
  description   = "Athena workgroup for multi-cloud-finops CUR 2.0 queries"
  force_destroy = true

  configuration {
    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = true

    result_configuration {
      output_location = "s3://${aws_s3_bucket.athena_results.bucket}/results/"
      encryption_configuration {
        encryption_option = "SSE_S3"
      }
    }

    # Per-query data scan cap. CUR 2.0 is partitioned by BILLING_PERIOD,
    # so a sane query touches a few hundred MB at most. A runaway query
    # that scans multiple months without a partition filter gets stopped
    # before it bills real money.
    bytes_scanned_cutoff_per_query = 10 * 1024 * 1024 * 1024 # 10 GiB
  }
}

resource "aws_glue_catalog_database" "cur" {
  name        = var.glue_database_name
  description = "Glue database holding the CUR 2.0 external table"
}

# IAM role the crawler assumes. Minimum rights: read the CUR bucket,
# write Glue catalog entries, write CloudWatch logs for its own runs.
# No PutObject on the CUR bucket - the crawler discovers, it does not
# rewrite the data.

data "aws_iam_policy_document" "crawler_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["glue.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "crawler" {
  name               = "${var.cur_export_name}-crawler"
  description        = "Role Glue crawler assumes to catalog the CUR 2.0 bucket"
  assume_role_policy = data.aws_iam_policy_document.crawler_assume.json
}

# Managed policy wires up the Glue service permissions; CloudWatch
# Logs are the crawler's own observability path.
resource "aws_iam_role_policy_attachment" "crawler_service" {
  role       = aws_iam_role.crawler.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
}

data "aws_iam_policy_document" "crawler_s3_read" {
  statement {
    effect  = "Allow"
    actions = ["s3:GetObject", "s3:GetBucketLocation"]
    resources = [
      aws_s3_bucket.cur.arn,
      "${aws_s3_bucket.cur.arn}/*",
    ]
  }
  statement {
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.cur.arn]
  }
}

resource "aws_iam_role_policy" "crawler_s3_read" {
  name   = "s3-read-cur"
  role   = aws_iam_role.crawler.id
  policy = data.aws_iam_policy_document.crawler_s3_read.json
}

# Crawler runs once a day at 04:00 UTC. CUR 2.0 refreshes its
# in-progress month multiple times a day but closed months do not
# change, so a daily cadence catches every new BILLING_PERIOD
# partition before the next working day in PT.
resource "aws_glue_crawler" "cur" {
  name          = "${var.cur_export_name}-crawler"
  database_name = aws_glue_catalog_database.cur.name
  role          = aws_iam_role.crawler.arn
  schedule      = "cron(0 4 * * ? *)"
  description   = "Daily crawler that keeps the Athena CUR 2.0 table in sync with S3 partitions"

  s3_target {
    path = "s3://${aws_s3_bucket.cur.bucket}/${var.cur_s3_prefix}/${var.cur_export_name}/data/"
  }

  configuration = jsonencode({
    Version = 1.0
    CrawlerOutput = {
      Partitions = { AddOrUpdateBehavior = "InheritFromTable" }
    }
    Grouping = {
      TableGroupingPolicy = "CombineCompatibleSchemas"
    }
  })

  schema_change_policy {
    update_behavior = "UPDATE_IN_DATABASE"
    delete_behavior = "LOG"
  }
}

# ---------------------------------------------------------------------------
# IAM user Grafana uses to query Athena.
# ---------------------------------------------------------------------------
#
# The Athena datasource plugin authenticates with long-lived access
# keys. That is not ideal (IAM roles would be better) but Grafana on
# the homelab Pi is not running inside AWS and has no IRSA-equivalent.
# The keys live in Grafana's secret store, the IAM user has no console
# access, and the policy is scoped to exactly the Athena workgroup and
# the two S3 buckets involved.

resource "aws_iam_user" "grafana" {
  name = var.grafana_iam_user_name
  path = "/multi-cloud-finops/"
  tags = {
    Project = "multi-cloud-finops"
    Purpose = "Grafana Athena datasource reader"
  }
}

data "aws_iam_policy_document" "grafana_athena_reader" {
  # Athena: workgroup-scoped actions (query execution + workgroup + data
  # catalog metadata) are restricted to the project's workgroup and
  # datacatalog ARNs. The Grafana plugin UI also needs account-level
  # List actions (ListWorkGroups, ListDataCatalogs, ListDatabases,
  # ListTableMetadata) to populate its dropdowns, and these do NOT
  # support resource-level scoping - IAM rejects any resource-bound
  # policy on them. So they live in a separate statement with
  # Resource "*" and no PutQueryResults path, which keeps the
  # read-only-on-account-metadata property intact.
  statement {
    sid    = "AthenaQueryExecutionScoped"
    effect = "Allow"
    actions = [
      "athena:StartQueryExecution",
      "athena:StopQueryExecution",
      "athena:GetQueryExecution",
      "athena:GetQueryResults",
      "athena:GetQueryResultsStream",
      "athena:GetWorkGroup",
      "athena:ListQueryExecutions",
      "athena:GetDatabase",
      "athena:GetDataCatalog",
      "athena:GetTableMetadata",
    ]
    resources = [
      aws_athena_workgroup.finops.arn,
      "arn:aws:athena:${var.aws_region}:${var.aws_account_id}:datacatalog/*",
    ]
  }

  statement {
    sid    = "AthenaListAccountLevel"
    effect = "Allow"
    actions = [
      "athena:ListWorkGroups",
      "athena:ListDataCatalogs",
      "athena:ListDatabases",
      "athena:ListTableMetadata",
      "athena:ListEngineVersions",
    ]
    resources = ["*"]
  }

  # Glue: read-only access to the crawler-maintained catalog. The
  # Grafana plugin needs this to populate Database and Table dropdowns
  # the same way the BigQuery plugin needs bigquery.metadataViewer.
  statement {
    sid    = "GlueCatalogRead"
    effect = "Allow"
    actions = [
      "glue:GetDatabase",
      "glue:GetDatabases",
      "glue:GetTable",
      "glue:GetTables",
      "glue:GetPartition",
      "glue:GetPartitions",
    ]
    resources = [
      "arn:aws:glue:${var.aws_region}:${var.aws_account_id}:catalog",
      "arn:aws:glue:${var.aws_region}:${var.aws_account_id}:database/${aws_glue_catalog_database.cur.name}",
      "arn:aws:glue:${var.aws_region}:${var.aws_account_id}:table/${aws_glue_catalog_database.cur.name}/*",
    ]
  }

  # S3: read the CUR data, write + read own Athena query results. Two
  # buckets, two scopes - the CUR bucket is read-only, the results
  # bucket is read/write because Athena stages result sets there.
  statement {
    sid    = "S3ReadCUR"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:GetBucketLocation",
      "s3:ListBucket",
    ]
    resources = [
      aws_s3_bucket.cur.arn,
      "${aws_s3_bucket.cur.arn}/*",
    ]
  }

  statement {
    sid    = "S3WriteAthenaResults"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:AbortMultipartUpload",
      "s3:ListBucket",
      "s3:ListMultipartUploadParts",
      "s3:GetBucketLocation",
    ]
    resources = [
      aws_s3_bucket.athena_results.arn,
      "${aws_s3_bucket.athena_results.arn}/*",
    ]
  }
}

resource "aws_iam_user_policy" "grafana_athena_reader" {
  name   = "athena-reader"
  user   = aws_iam_user.grafana.name
  policy = data.aws_iam_policy_document.grafana_athena_reader.json
}

# Access key for the IAM user. Marked sensitive and returned via
# `terraform output -raw grafana_aws_secret_key` so the secret never
# ends up in terminal scrollback by accident. The user commits the
# access key id to the datasource provisioning file; the secret key
# goes into Grafana's secret store.
resource "aws_iam_access_key" "grafana" {
  user = aws_iam_user.grafana.name
}
