###############################################################################
# Shared lookups and locals
###############################################################################

data "aws_caller_identity" "current" {}

locals {
  # The topic ARN alerts are routed to: either the one created here or a
  # caller-supplied existing topic.
  alert_topic_arn = var.create_sns_topic ? aws_sns_topic.cost_alerts[0].arn : var.existing_sns_topic_arn

  # The highest configured threshold drives an additional FORECASTED alarm so
  # projected overruns surface before the money is actually spent.
  max_budget_threshold = max(var.budget_alert_thresholds_percent...)
}

###############################################################################
# SNS alert topic
###############################################################################

resource "aws_sns_topic" "cost_alerts" {
  count = var.create_sns_topic ? 1 : 0

  name = "${var.name_prefix}-cost-alerts"

  # Server-side encryption with the AWS-managed SNS key. Budgets and Cost
  # Anomaly Detection can publish to a topic encrypted with the AWS-managed
  # key without extra key-policy grants.
  kms_master_key_id = "alias/aws/sns"

  tags = { Name = "${var.name_prefix}-cost-alerts" }
}

# Allow the AWS cost-management principals to publish to the topic, scoped to
# this account to guard against the confused-deputy problem.
data "aws_iam_policy_document" "cost_alerts" {
  count = var.create_sns_topic ? 1 : 0

  statement {
    sid    = "AllowCostManagementServicesPublish"
    effect = "Allow"

    principals {
      type = "Service"
      identifiers = [
        "budgets.amazonaws.com",
        "costalerts.amazonaws.com",
      ]
    }

    actions   = ["SNS:Publish"]
    resources = [aws_sns_topic.cost_alerts[0].arn]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_sns_topic_policy" "cost_alerts" {
  count = var.create_sns_topic ? 1 : 0

  arn    = aws_sns_topic.cost_alerts[0].arn
  policy = data.aws_iam_policy_document.cost_alerts[0].json
}

# Email subscriptions. Each recipient must confirm the opt-in email before AWS
# starts delivering notifications.
resource "aws_sns_topic_subscription" "email" {
  for_each = var.create_sns_topic ? toset(var.alert_email_addresses) : toset([])

  topic_arn = aws_sns_topic.cost_alerts[0].arn
  protocol  = "email"
  endpoint  = each.value
}

###############################################################################
# Account-wide monthly cost budget
###############################################################################

resource "aws_budgets_budget" "monthly_cost" {
  name         = "${var.name_prefix}-monthly-cost"
  budget_type  = "COST"
  limit_amount = format("%.2f", var.monthly_budget_amount)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  # Measure blended, amortized cost excluding credits and refunds so the alert
  # tracks real consumption rather than one-off adjustments.
  cost_types {
    include_credit             = false
    include_refund             = false
    include_upfront            = true
    include_recurring          = true
    include_other_subscription = true
    include_subscription       = true
    include_support            = true
    include_tax                = true
    use_amortized              = true
  }

  # ACTUAL-spend notifications at each configured threshold.
  dynamic "notification" {
    for_each = toset(var.budget_alert_thresholds_percent)

    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = notification.value
      threshold_type             = "PERCENTAGE"
      notification_type          = "ACTUAL"
      subscriber_sns_topic_arns  = [local.alert_topic_arn]
    }
  }

  # A single FORECASTED notification at the highest threshold gives early
  # warning of a projected overrun.
  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = local.max_budget_threshold
    threshold_type            = "PERCENTAGE"
    notification_type         = "FORECASTED"
    subscriber_sns_topic_arns = [local.alert_topic_arn]
  }

  # Ensure the publish grant exists before AWS validates the SNS target.
  depends_on = [aws_sns_topic_policy.cost_alerts]
}

###############################################################################
# Optional per-service budgets
###############################################################################

resource "aws_budgets_budget" "service" {
  for_each = var.service_budgets

  name         = "${var.name_prefix}-service-${each.key}"
  budget_type  = "COST"
  limit_amount = format("%.2f", each.value.amount)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_filter {
    name   = "Service"
    values = [each.value.dimension_value]
  }

  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = each.value.threshold_percent
    threshold_type            = "PERCENTAGE"
    notification_type         = "ACTUAL"
    subscriber_sns_topic_arns = [local.alert_topic_arn]
  }

  depends_on = [aws_sns_topic_policy.cost_alerts]
}

###############################################################################
# Cost Anomaly Detection
###############################################################################

# Monitors every service using AWS's machine-learning baseline. Anomalies are
# grouped per service so the notification names the driver of the spike.
resource "aws_ce_anomaly_monitor" "service" {
  count = var.enable_anomaly_detection ? 1 : 0

  name              = "${var.name_prefix}-service-monitor"
  monitor_type      = "DIMENSIONAL"
  monitor_dimension = "SERVICE"
}

resource "aws_ce_anomaly_subscription" "alerts" {
  count = var.enable_anomaly_detection ? 1 : 0

  name      = "${var.name_prefix}-anomaly-alerts"
  frequency = var.anomaly_notification_frequency

  monitor_arn_list = [aws_ce_anomaly_monitor.service[0].arn]

  subscriber {
    type    = "SNS"
    address = local.alert_topic_arn
  }

  # Only raise notifications once the absolute dollar impact clears the
  # configured floor, cutting noise from trivial fluctuations.
  threshold_expression {
    dimension {
      key           = "ANOMALY_TOTAL_IMPACT_ABSOLUTE"
      match_options = ["GREATER_THAN_OR_EQUAL"]
      values        = [tostring(var.anomaly_total_impact_threshold)]
    }
  }

  depends_on = [aws_sns_topic_policy.cost_alerts]
}
