###############################################################################
# Idle-resource cleanup reporting
#
# A scheduled Lambda scans the account for resources that accrue cost while
# sitting idle (unattached EBS volumes, unassociated Elastic IPs, and stale EBS
# snapshots), skips anything carrying an exclusion tag key, writes a JSON report
# to S3, and publishes a summary to the shared cost-alert topic. The function is
# read-only against the account: it reports candidates but never deletes them.
###############################################################################

locals {
  idle_finder_enabled = var.enable_idle_finder
  idle_finder_count   = local.idle_finder_enabled ? 1 : 0

  idle_finder_fn_name    = "${var.name_prefix}-idle-resource-finder"
  idle_report_bucket_name = "${var.name_prefix}-idle-resource-reports-${data.aws_caller_identity.current.account_id}"
}

###############################################################################
# Report bucket (encrypted with the shared finops KMS key)
###############################################################################

resource "aws_s3_bucket" "idle_reports" {
  count = local.idle_finder_count

  bucket = local.idle_report_bucket_name
  tags   = { Name = local.idle_report_bucket_name }
}

resource "aws_s3_bucket_ownership_controls" "idle_reports" {
  count = local.idle_finder_count

  bucket = aws_s3_bucket.idle_reports[0].id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "idle_reports" {
  count = local.idle_finder_count

  bucket                  = aws_s3_bucket.idle_reports[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "idle_reports" {
  count = local.idle_finder_count

  bucket = aws_s3_bucket.idle_reports[0].id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "idle_reports" {
  count = local.idle_finder_count

  bucket = aws_s3_bucket.idle_reports[0].id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = local.finops_key_arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "idle_reports" {
  count = local.idle_finder_count

  bucket = aws_s3_bucket.idle_reports[0].id

  rule {
    id     = "expire-reports"
    status = "Enabled"

    filter {}

    expiration {
      days = var.idle_report_retention_days
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# Deny any non-TLS access to the bucket.
data "aws_iam_policy_document" "idle_reports" {
  count = local.idle_finder_count

  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.idle_reports[0].arn,
      "${aws_s3_bucket.idle_reports[0].arn}/*",
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

resource "aws_s3_bucket_policy" "idle_reports" {
  count = local.idle_finder_count

  bucket = aws_s3_bucket.idle_reports[0].id
  policy = data.aws_iam_policy_document.idle_reports[0].json
}

###############################################################################
# Lambda IAM role
###############################################################################

data "aws_iam_policy_document" "idle_finder_assume" {
  count = local.idle_finder_count

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "idle_finder" {
  count = local.idle_finder_count

  name               = local.idle_finder_fn_name
  assume_role_policy = data.aws_iam_policy_document.idle_finder_assume[0].json
}

data "aws_iam_policy_document" "idle_finder" {
  count = local.idle_finder_count

  # Read-only discovery. The EC2 Describe* calls are account-wide and do not
  # support resource-level scoping, so they are granted on "*".
  statement {
    sid    = "DescribeCandidates"
    effect = "Allow"
    actions = [
      "ec2:DescribeVolumes",
      "ec2:DescribeAddresses",
      "ec2:DescribeSnapshots",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "WriteReports"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.idle_reports[0].arn}/*"]
  }

  statement {
    sid    = "UseReportKey"
    effect = "Allow"
    actions = [
      "kms:GenerateDataKey",
      "kms:Encrypt",
      "kms:Decrypt",
    ]
    resources = [local.finops_key_arn]
  }

  statement {
    sid       = "PublishSummary"
    effect    = "Allow"
    actions   = ["SNS:Publish"]
    resources = [local.alert_topic_arn]
  }

  statement {
    sid    = "WriteLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["${aws_cloudwatch_log_group.idle_finder[0].arn}:*"]
  }
}

resource "aws_iam_role_policy" "idle_finder" {
  count = local.idle_finder_count

  name   = local.idle_finder_fn_name
  role   = aws_iam_role.idle_finder[0].id
  policy = data.aws_iam_policy_document.idle_finder[0].json
}

###############################################################################
# Lambda function, log group, and schedule
###############################################################################

data "archive_file" "idle_finder" {
  count = local.idle_finder_count

  type        = "zip"
  source_file = "${path.module}/lambda/idle-finder/handler.py"
  output_path = "${path.module}/.build/idle-finder.zip"
}

resource "aws_cloudwatch_log_group" "idle_finder" {
  count = local.idle_finder_count

  name              = "/aws/lambda/${local.idle_finder_fn_name}"
  retention_in_days = var.log_retention_days
  kms_key_id        = local.finops_key_arn
}

resource "aws_lambda_function" "idle_finder" {
  count = local.idle_finder_count

  function_name = local.idle_finder_fn_name
  role          = aws_iam_role.idle_finder[0].arn
  runtime       = "python3.12"
  handler       = "handler.handler"
  timeout       = 300
  memory_size   = 256

  filename         = data.archive_file.idle_finder[0].output_path
  source_code_hash = data.archive_file.idle_finder[0].output_base64sha256

  environment {
    variables = {
      REPORT_BUCKET           = aws_s3_bucket.idle_reports[0].id
      REPORT_PREFIX           = "idle-resources/"
      SNS_TOPIC_ARN           = local.alert_topic_arn
      STALE_SNAPSHOT_AGE_DAYS = tostring(var.stale_snapshot_age_days)
      ORPHANED_SNAPSHOTS_ONLY = tostring(var.orphaned_snapshots_only)
      EXCLUSION_TAG_KEYS      = join(",", var.idle_exclusion_tag_keys)
      LOG_LEVEL               = "INFO"
    }
  }

  # X-Ray active tracing aids debugging of the scheduled run.
  tracing_config {
    mode = "Active"
  }

  depends_on = [
    aws_iam_role_policy.idle_finder,
    aws_cloudwatch_log_group.idle_finder,
  ]
}

resource "aws_cloudwatch_event_rule" "idle_finder" {
  count = local.idle_finder_count

  name                = local.idle_finder_fn_name
  description         = "Triggers the idle-resource finder report"
  schedule_expression = var.idle_finder_schedule_expression
}

resource "aws_cloudwatch_event_target" "idle_finder" {
  count = local.idle_finder_count

  rule      = aws_cloudwatch_event_rule.idle_finder[0].name
  target_id = "idle-resource-finder"
  arn       = aws_lambda_function.idle_finder[0].arn
}

resource "aws_lambda_permission" "idle_finder_events" {
  count = local.idle_finder_count

  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.idle_finder[0].function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.idle_finder[0].arn
}
