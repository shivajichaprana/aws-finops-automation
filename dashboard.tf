###############################################################################
# Monthly cost dashboard
#
# A CloudWatch dashboard summarizing estimated charges: a total spend figure, a
# spend-over-time trend, and a per-service breakdown. It reads the AWS/Billing
# EstimatedCharges metric, which is published only to the us-east-1 CloudWatch
# endpoint and refreshes roughly every six hours, resetting at the start of each
# billing period. The cost-management provider already targets that region, so
# the widgets resolve the metric without a second provider alias.
###############################################################################

locals {
  cost_dashboard_enabled = var.enable_cost_dashboard

  # AWS/Billing EstimatedCharges publishes to us-east-1 regardless of where the
  # rest of the estate runs; the widgets pin that region explicitly.
  billing_metric_region = var.cost_management_region

  # Billing metrics update on a multi-hour cadence, so a coarse period keeps the
  # widgets from rendering sparse gaps. Maximum reflects the running month-to-date
  # total, which only ever climbs within a billing period.
  billing_metric_period = 21600 # 6 hours, in seconds
  billing_metric_stat   = "Maximum"

  # One metric line per service charted on the breakdown widget. EstimatedCharges
  # carries a ServiceName dimension per service alongside the Currency dimension.
  service_metric_lines = [
    for service_name in var.dashboard_service_dimensions :
    ["AWS/Billing", "EstimatedCharges", "ServiceName", service_name, "Currency", "USD"]
  ]

  cost_dashboard_widgets = [
    {
      type   = "text"
      x      = 0
      y      = 0
      width  = 24
      height = 2
      properties = {
        markdown = "# ${var.name_prefix} — estimated charges\nBilling metrics refresh roughly every six hours and reset at the start of each billing period. All values are in USD."
      }
    },
    {
      type   = "metric"
      x      = 0
      y      = 2
      width  = 8
      height = 6
      properties = {
        title   = "Total estimated charges (USD)"
        view    = "singleValue"
        region  = local.billing_metric_region
        stat    = local.billing_metric_stat
        period  = local.billing_metric_period
        metrics = [["AWS/Billing", "EstimatedCharges", "Currency", "USD"]]
      }
    },
    {
      type   = "metric"
      x      = 8
      y      = 2
      width  = 16
      height = 6
      properties = {
        title   = "Total estimated charges over time (USD)"
        view    = "timeSeries"
        stacked = false
        region  = local.billing_metric_region
        stat    = local.billing_metric_stat
        period  = local.billing_metric_period
        metrics = [["AWS/Billing", "EstimatedCharges", "Currency", "USD"]]
      }
    },
    {
      type   = "metric"
      x      = 0
      y      = 8
      width  = 24
      height = 8
      properties = {
        title   = "Estimated charges by service (USD)"
        view    = "timeSeries"
        stacked = true
        region  = local.billing_metric_region
        stat    = local.billing_metric_stat
        period  = local.billing_metric_period
        metrics = local.service_metric_lines
      }
    },
  ]
}

resource "aws_cloudwatch_dashboard" "cost" {
  count = local.cost_dashboard_enabled ? 1 : 0

  dashboard_name = "${var.name_prefix}-monthly-cost"
  dashboard_body = jsonencode({ widgets = local.cost_dashboard_widgets })
}
