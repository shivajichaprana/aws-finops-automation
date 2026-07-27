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
