###############################################################################
# Rightsizing report pipeline
#
# A scheduled Lambda reads AWS Compute Optimizer recommendations, estimates the
# achievable monthly savings, writes a JSON report to S3, and publishes a
# summary to the shared cost-alert topic. Everything is read-only against the
# account; the function never mutates a resource.
###############################################################################

locals {
  rightsizing_enabled  = var.enable_rightsizing_report
  rightsizing_count    = local.rightsizing_enabled ? 1 : 0

  # The shared KMS key is needed whenever reports are written or Athena results
  # are encrypted, so it outlives the rightsizing pipeline alone.
  finops_key_count = (var.enable_rightsizing_report || var.enable_athena_cost_views || var.enable_idle_finder) ? 1 : 0
  rightsizing_fn_name  = "${var.name_prefix}-rightsizing-report"
  report_bucket_name   = "${var.name_prefix}-rightsizing-reports-${data.aws_caller_identity.current.account_id}"
}

###############################################################################
# Encryption key shared by the report bucket and the Lambda log group
###############################################################################

resource "aws_kms_key" "finops" {
  count = local.finops_key_count

  description             = "Encrypts finops rightsizing reports and logs"
  deletion_window_in_days = 30
  enable_key_rotation     = true
}

resource "aws_kms_alias" "finops" {
  count = local.finops_key_count

  name          = "alias/${var.name_prefix}-rightsizing"
  target_key_id = aws_kms_key.finops[0].key_id
}

# Allow CloudWatch Logs in this region to use the key for the Lambda log group.
data "aws_iam_policy_document" "finops_key" {
  count = local.finops_key_count

  # Full control retained by the account root so the key stays manageable.
  statement {
    sid       = "EnableRootAccountAdmin"
    effect    = "Allow"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }

  statement {
    sid    = "AllowCloudWatchLogs"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["logs.${var.cost_management_region}.amazonaws.com"]
    }

    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:DescribeKey",
    ]
    resources = ["*"]

    condition {
      test     = "ArnLike"
      variable = "kms:EncryptionContext:aws:logs:arn"
      values   = ["arn:${data.aws_partition.current.partition}:logs:${var.cost_management_region}:${data.aws_caller_identity.current.account_id}:log-group:*"]
    }
  }
}

resource "aws_kms_key_policy" "finops" {
  count = local.finops_key_count

  key_id = aws_kms_key.finops[0].id
  policy = data.aws_iam_policy_document.finops_key[0].json
}

###############################################################################
# Report bucket
###############################################################################

resource "aws_s3_bucket" "reports" {
  count = local.rightsizing_count

  bucket = local.report_bucket_name
  tags   = { Name = local.report_bucket_name }
}

resource "aws_s3_bucket_ownership_controls" "reports" {
  count = local.rightsizing_count

  bucket = aws_s3_bucket.reports[0].id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "reports" {
  count = local.rightsizing_count

  bucket                  = aws_s3_bucket.reports[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "reports" {
  count = local.rightsizing_count

  bucket = aws_s3_bucket.reports[0].id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "reports" {
  count = local.rightsizing_count

  bucket = aws_s3_bucket.reports[0].id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.finops[0].arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "reports" {
  count = local.rightsizing_count

  bucket = aws_s3_bucket.reports[0].id

  rule {
    id     = "expire-reports"
    status = "Enabled"

    filter {}

    expiration {
      days = var.report_retention_days
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
data "aws_iam_policy_document" "reports" {
  count = local.rightsizing_count

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [
      aws_s3_bucket.reports[0].arn,
      "${aws_s3_bucket.reports[0].arn}/*",
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

resource "aws_s3_bucket_policy" "reports" {
  count = local.rightsizing_count

  bucket = aws_s3_bucket.reports[0].id
  policy = data.aws_iam_policy_document.reports[0].json
}

###############################################################################
# Lambda IAM role
###############################################################################

data "aws_iam_policy_document" "rightsizing_assume" {
  count = local.rightsizing_count

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "rightsizing" {
  count = local.rightsizing_count

  name               = "${var.name_prefix}-rightsizing-report"
  assume_role_policy = data.aws_iam_policy_document.rightsizing_assume[0].json
}

data "aws_iam_policy_document" "rightsizing" {
  count = local.rightsizing_count

  # Compute Optimizer read-only. The Get* recommendation calls do not support
  # resource-level scoping, so they are granted on "*".
  statement {
    sid    = "ComputeOptimizerRead"
    effect = "Allow"
    actions = [
      "compute-optimizer:GetEC2InstanceRecommendations",
      "compute-optimizer:GetAutoScalingGroupRecommendations",
      "compute-optimizer:GetEBSVolumeRecommendations",
      "compute-optimizer:GetLambdaFunctionRecommendations",
      "compute-optimizer:GetEnrollmentStatus",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "WriteReports"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.reports[0].arn}/*"]
  }

  statement {
    sid    = "UseReportKey"
    effect = "Allow"
    actions = [
      "kms:GenerateDataKey",
      "kms:Encrypt",
      "kms:Decrypt",
    ]
    resources = [aws_kms_key.finops[0].arn]
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
    resources = ["${aws_cloudwatch_log_group.rightsizing[0].arn}:*"]
  }
}

resource "aws_iam_role_policy" "rightsizing" {
  count = local.rightsizing_count

  name   = "${var.name_prefix}-rightsizing-report"
  role   = aws_iam_role.rightsizing[0].id
  policy = data.aws_iam_policy_document.rightsizing[0].json
}

###############################################################################
# Lambda function, log group, and schedule
###############################################################################

data "archive_file" "rightsizing" {
  count = local.rightsizing_count

  type        = "zip"
  source_file = "${path.module}/lambda/rightsizing/handler.py"
  output_path = "${path.module}/.build/rightsizing.zip"
}

resource "aws_cloudwatch_log_group" "rightsizing" {
  count = local.rightsizing_count

  name              = "/aws/lambda/${local.rightsizing_fn_name}"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.finops[0].arn
}

resource "aws_lambda_function" "rightsizing" {
  count = local.rightsizing_count

  function_name = local.rightsizing_fn_name
  role          = aws_iam_role.rightsizing[0].arn
  runtime       = "python3.12"
  handler       = "handler.handler"
  timeout       = 300
  memory_size   = 256

  filename         = data.archive_file.rightsizing[0].output_path
  source_code_hash = data.archive_file.rightsizing[0].output_base64sha256

  environment {
    variables = {
      REPORT_BUCKET       = aws_s3_bucket.reports[0].id
      REPORT_PREFIX       = "rightsizing/"
      SNS_TOPIC_ARN       = local.alert_topic_arn
      SAVINGS_THRESHOLD   = tostring(var.rightsizing_savings_threshold)
      RECOMMENDATION_RANK = tostring(var.rightsizing_recommendation_rank)
      LOG_LEVEL           = "INFO"
    }
  }

  # X-Ray active tracing aids debugging of the scheduled run.
  tracing_config {
    mode = "Active"
  }

  depends_on = [
    aws_iam_role_policy.rightsizing,
    aws_cloudwatch_log_group.rightsizing,
  ]
}

resource "aws_cloudwatch_event_rule" "rightsizing" {
  count = local.rightsizing_count

  name                = "${var.name_prefix}-rightsizing-report"
  description         = "Triggers the Compute Optimizer rightsizing report"
  schedule_expression = var.rightsizing_schedule_expression
}

resource "aws_cloudwatch_event_target" "rightsizing" {
  count = local.rightsizing_count

  rule      = aws_cloudwatch_event_rule.rightsizing[0].name
  target_id = "rightsizing-report"
  arn       = aws_lambda_function.rightsizing[0].arn
}

resource "aws_lambda_permission" "rightsizing_events" {
  count = local.rightsizing_count

  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.rightsizing[0].function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.rightsizing[0].arn
}
