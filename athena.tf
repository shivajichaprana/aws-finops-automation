###############################################################################
# Athena cost views over the Cost and Usage Report (CUR)
#
# Registers a set of analysis views as Athena named queries. This depends on an
# existing CUR Glue table, so the whole block is gated behind
# enable_athena_cost_views and validated against the two CUR identifiers.
###############################################################################

data "aws_partition" "current" {}

locals {
  athena_enabled = var.enable_athena_cost_views
  athena_count   = local.athena_enabled ? 1 : 0

  # Fully-qualified CUR table reference used inside the view templates.
  cur_table_fqn = local.athena_enabled ? "${var.cur_database_name}.${var.cur_table_name}" : ""

  athena_results_bucket = "${var.name_prefix}-athena-results-${data.aws_caller_identity.current.account_id}"
  views_database_name   = replace("${var.name_prefix}_cost_views", "-", "_")

  # The view SQL templates rendered into named queries.
  cost_view_files = local.athena_enabled ? fileset("${path.module}/athena", "*.sql") : toset([])

  # Non-null whenever the shared finops KMS key exists (see rightsizing.tf).
  finops_key_arn = one(aws_kms_key.finops[*].arn)
}

# Fail fast if the feature is enabled without the CUR identifiers it needs.
resource "terraform_data" "athena_prerequisites" {
  count = local.athena_count

  lifecycle {
    precondition {
      condition     = var.cur_database_name != null && var.cur_table_name != null
      error_message = "enable_athena_cost_views requires both cur_database_name and cur_table_name."
    }
  }
}

###############################################################################
# Query-results bucket
###############################################################################

resource "aws_s3_bucket" "athena_results" {
  count = local.athena_count

  bucket = local.athena_results_bucket
  tags   = { Name = local.athena_results_bucket }
}

resource "aws_s3_bucket_ownership_controls" "athena_results" {
  count = local.athena_count

  bucket = aws_s3_bucket.athena_results[0].id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "athena_results" {
  count = local.athena_count

  bucket                  = aws_s3_bucket.athena_results[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "athena_results" {
  count = local.athena_count

  bucket = aws_s3_bucket.athena_results[0].id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "athena_results" {
  count = local.athena_count

  bucket = aws_s3_bucket.athena_results[0].id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
      # Reuse the finops key when the rightsizing pipeline is on; otherwise the
      # AWS-managed S3 key is used implicitly (null selects SSE-KMS default).
      kms_master_key_id = local.finops_key_arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "athena_results" {
  count = local.athena_count

  bucket = aws_s3_bucket.athena_results[0].id

  rule {
    id     = "expire-results"
    status = "Enabled"

    filter {}

    expiration {
      days = var.athena_results_retention_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

data "aws_iam_policy_document" "athena_results" {
  count = local.athena_count

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [
      aws_s3_bucket.athena_results[0].arn,
      "${aws_s3_bucket.athena_results[0].arn}/*",
    ]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "athena_results" {
  count = local.athena_count

  bucket = aws_s3_bucket.athena_results[0].id
  policy = data.aws_iam_policy_document.athena_results[0].json
}

###############################################################################
# Workgroup, views database, and named queries
###############################################################################

resource "aws_athena_workgroup" "finops" {
  count = local.athena_count

  name          = "${var.name_prefix}-cost-views"
  force_destroy = true

  configuration {
    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = true

    result_configuration {
      output_location = "s3://${aws_s3_bucket.athena_results[0].id}/query-results/"

      encryption_configuration {
        encryption_option = "SSE_KMS"
        kms_key_arn       = local.finops_key_arn
      }
    }
  }
}

# Database that the analysis views are created in. Distinct from the CUR
# database so the raw report schema is never mutated.
resource "aws_glue_catalog_database" "cost_views" {
  count = local.athena_count

  name        = local.views_database_name
  description = "Analysis views derived from the Cost and Usage Report"
}

resource "aws_athena_named_query" "cost_view" {
  for_each = {
    for file in local.cost_view_files : file => file
  }

  name      = "finops-view-${replace(each.value, ".sql", "")}"
  workgroup = aws_athena_workgroup.finops[0].name
  database  = aws_glue_catalog_database.cost_views[0].name

  query = templatefile("${path.module}/athena/${each.value}", {
    cur_table      = local.cur_table_fqn
    views_database = aws_glue_catalog_database.cost_views[0].name
  })

  description = "Cost analysis view rendered from ${each.value}"
}
