output "alert_topic_arn" {
  description = "ARN of the SNS topic that cost alerts are published to."
  value       = local.alert_topic_arn
}

output "monthly_budget_name" {
  description = "Name of the account-wide monthly cost budget."
  value       = aws_budgets_budget.monthly_cost.name
}

output "service_budget_names" {
  description = "Names of the per-service budgets, keyed by their configuration label."
  value       = { for label, budget in aws_budgets_budget.service : label => budget.name }
}

output "anomaly_monitor_arn" {
  description = "ARN of the Cost Anomaly Detection monitor, or null when anomaly detection is disabled."
  value       = var.enable_anomaly_detection ? aws_ce_anomaly_monitor.service[0].arn : null
}

output "anomaly_subscription_arn" {
  description = "ARN of the Cost Anomaly Detection subscription, or null when anomaly detection is disabled."
  value       = var.enable_anomaly_detection ? aws_ce_anomaly_subscription.alerts[0].arn : null
}

output "rightsizing_report_bucket" {
  description = "S3 bucket rightsizing reports are written to, or null when the report is disabled."
  value       = local.rightsizing_enabled ? aws_s3_bucket.reports[0].id : null
}

output "rightsizing_function_name" {
  description = "Name of the rightsizing report Lambda, or null when the report is disabled."
  value       = local.rightsizing_enabled ? aws_lambda_function.rightsizing[0].function_name : null
}

output "rightsizing_schedule_rule" {
  description = "EventBridge rule that triggers the rightsizing report, or null when disabled."
  value       = local.rightsizing_enabled ? aws_cloudwatch_event_rule.rightsizing[0].name : null
}

output "finops_kms_key_arn" {
  description = "ARN of the KMS key encrypting reports and logs, or null when the rightsizing pipeline is disabled."
  value       = local.rightsizing_enabled ? aws_kms_key.finops[0].arn : null
}

output "athena_workgroup_name" {
  description = "Athena workgroup hosting the cost views, or null when the views are disabled."
  value       = local.athena_enabled ? aws_athena_workgroup.finops[0].name : null
}

output "cost_views_database" {
  description = "Glue database the cost views are created in, or null when the views are disabled."
  value       = local.athena_enabled ? aws_glue_catalog_database.cost_views[0].name : null
}

output "cost_view_query_names" {
  description = "Names of the registered Athena named queries for the cost views."
  value       = [for q in aws_athena_named_query.cost_view : q.name]
}
