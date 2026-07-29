###############################################################################
# Global configuration
###############################################################################

variable "cost_management_region" {
  description = "Region used for the AWS cost-management control plane (Budgets, Cost Anomaly Detection, Cost Explorer). These are global services reached through us-east-1."
  type        = string
  default     = "us-east-1"
}

variable "name_prefix" {
  description = "Prefix applied to the names of created resources so they group cleanly in the console and billing."
  type        = string
  default     = "finops"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,30}[a-z0-9]$", var.name_prefix))
    error_message = "name_prefix must be 3-32 chars, lowercase alphanumeric or hyphen, starting with a letter."
  }
}

variable "tags" {
  description = "Additional tags merged onto every managed resource."
  type        = map(string)
  default     = {}
}

###############################################################################
# Notification routing
###############################################################################

variable "alert_email_addresses" {
  description = "Email addresses subscribed to the cost-alert SNS topic. Each subscriber must confirm the emailed opt-in before delivery begins."
  type        = list(string)
  default     = []

  validation {
    condition = alltrue([
      for address in var.alert_email_addresses :
      can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", address))
    ])
    error_message = "Every entry in alert_email_addresses must be a valid email address."
  }
}

variable "create_sns_topic" {
  description = "Whether to create the alert SNS topic. Set false to reuse an existing topic supplied via existing_sns_topic_arn."
  type        = bool
  default     = true
}

variable "existing_sns_topic_arn" {
  description = "ARN of a pre-existing SNS topic to route alerts to. Only used when create_sns_topic is false."
  type        = string
  default     = null

  validation {
    condition     = var.existing_sns_topic_arn == null || can(regex("^arn:aws[a-z-]*:sns:", var.existing_sns_topic_arn))
    error_message = "existing_sns_topic_arn must be a valid SNS topic ARN or null."
  }
}

###############################################################################
# Budgets
###############################################################################

variable "monthly_budget_amount" {
  description = "Monthly cost budget ceiling, in USD, for the whole account."
  type        = number
  default     = 1000

  validation {
    condition     = var.monthly_budget_amount > 0
    error_message = "monthly_budget_amount must be greater than zero."
  }
}

variable "budget_alert_thresholds_percent" {
  description = "Percent-of-budget thresholds that raise an alert. ACTUAL spend crosses these; the highest value additionally drives a FORECASTED alarm."
  type        = list(number)
  default     = [50, 80, 100]

  validation {
    condition     = length(var.budget_alert_thresholds_percent) > 0
    error_message = "Provide at least one budget alert threshold."
  }

  validation {
    condition = alltrue([
      for pct in var.budget_alert_thresholds_percent : pct > 0 && pct <= 200
    ])
    error_message = "Budget thresholds must be between 1 and 200 percent."
  }
}

variable "service_budgets" {
  description = "Optional per-service monthly budgets, keyed by a short label. dimension_value is the AWS service name as it appears in Cost Explorer (e.g. \"Amazon Elastic Compute Cloud - Compute\")."
  type = map(object({
    amount           = number
    dimension_value  = string
    threshold_percent = optional(number, 100)
  }))
  default = {}

  validation {
    condition = alltrue([
      for label, cfg in var.service_budgets : cfg.amount > 0
    ])
    error_message = "Every service budget amount must be greater than zero."
  }
}

###############################################################################
# Cost Anomaly Detection
###############################################################################

variable "enable_anomaly_detection" {
  description = "Whether to create the Cost Anomaly Detection monitor and subscription."
  type        = bool
  default     = true
}

variable "anomaly_total_impact_threshold" {
  description = "Minimum absolute dollar impact (USD) of a detected anomaly before a notification is raised."
  type        = number
  default     = 100

  validation {
    condition     = var.anomaly_total_impact_threshold >= 0
    error_message = "anomaly_total_impact_threshold cannot be negative."
  }
}

variable "anomaly_notification_frequency" {
  description = "Cadence of anomaly notifications: IMMEDIATE, DAILY, or WEEKLY. IMMEDIATE requires an SNS target, which this configuration provisions."
  type        = string
  default     = "IMMEDIATE"

  validation {
    condition     = contains(["IMMEDIATE", "DAILY", "WEEKLY"], var.anomaly_notification_frequency)
    error_message = "anomaly_notification_frequency must be IMMEDIATE, DAILY, or WEEKLY."
  }
}

###############################################################################
# Rightsizing report
###############################################################################

variable "enable_rightsizing_report" {
  description = "Whether to deploy the Compute Optimizer rightsizing report Lambda, its report bucket, and its schedule."
  type        = bool
  default     = true
}

variable "rightsizing_schedule_expression" {
  description = "EventBridge schedule expression that triggers the rightsizing report. Defaults to weekly (Mondays 07:00 UTC)."
  type        = string
  default     = "cron(0 7 ? * MON *)"
}

variable "rightsizing_savings_threshold" {
  description = "Minimum estimated monthly USD savings for a recommendation to appear in the report."
  type        = number
  default     = 1

  validation {
    condition     = var.rightsizing_savings_threshold >= 0
    error_message = "rightsizing_savings_threshold cannot be negative."
  }
}

variable "rightsizing_recommendation_rank" {
  description = "Compute Optimizer recommendation option rank to report on: 1 (most conservative) to 3 (most aggressive)."
  type        = number
  default     = 1

  validation {
    condition     = var.rightsizing_recommendation_rank >= 1 && var.rightsizing_recommendation_rank <= 3
    error_message = "rightsizing_recommendation_rank must be between 1 and 3."
  }
}

variable "report_retention_days" {
  description = "Number of days rightsizing report objects are retained in S3 before expiry."
  type        = number
  default     = 365

  validation {
    condition     = var.report_retention_days >= 1
    error_message = "report_retention_days must be at least 1."
  }
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention, in days, for the rightsizing Lambda."
  type        = number
  default     = 90

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.log_retention_days)
    error_message = "log_retention_days must be a value supported by CloudWatch Logs."
  }
}

###############################################################################
# Athena cost views over the CUR
###############################################################################

variable "enable_athena_cost_views" {
  description = "Whether to register the Athena cost views over the CUR. Requires an existing CUR Glue table supplied via cur_database_name and cur_table_name."
  type        = bool
  default     = false
}

variable "cur_database_name" {
  description = "Glue database that contains the Cost and Usage Report table. Required when enable_athena_cost_views is true."
  type        = string
  default     = null
}

variable "cur_table_name" {
  description = "Glue table name of the Cost and Usage Report. Required when enable_athena_cost_views is true."
  type        = string
  default     = null
}

variable "athena_results_retention_days" {
  description = "Number of days Athena query result objects are retained before expiry."
  type        = number
  default     = 30

  validation {
    condition     = var.athena_results_retention_days >= 1
    error_message = "athena_results_retention_days must be at least 1."
  }
}

###############################################################################
# Idle-resource cleanup reporting
###############################################################################

variable "enable_idle_finder" {
  description = "Whether to deploy the idle-resource finder Lambda, its report bucket, and its schedule."
  type        = bool
  default     = true
}

variable "idle_finder_schedule_expression" {
  description = "EventBridge schedule expression that triggers the idle-resource finder. Defaults to weekly (Mondays 08:00 UTC)."
  type        = string
  default     = "cron(0 8 ? * MON *)"
}

variable "stale_snapshot_age_days" {
  description = "Minimum age, in days, for an EBS snapshot to be reported as stale."
  type        = number
  default     = 90

  validation {
    condition     = var.stale_snapshot_age_days >= 0
    error_message = "stale_snapshot_age_days cannot be negative."
  }
}

variable "orphaned_snapshots_only" {
  description = "When true, only snapshots whose source volume no longer exists are reported; otherwise every snapshot past the age threshold is reported."
  type        = bool
  default     = false
}

variable "idle_exclusion_tag_keys" {
  description = "Tag keys that exempt a resource from the idle-resource report. Any resource carrying one of these keys is skipped."
  type        = list(string)
  default     = ["finops:keep"]

  validation {
    condition     = length(var.idle_exclusion_tag_keys) > 0
    error_message = "Provide at least one exclusion tag key."
  }
}

variable "idle_report_retention_days" {
  description = "Number of days idle-resource report objects are retained in S3 before expiry."
  type        = number
  default     = 365

  validation {
    condition     = var.idle_report_retention_days >= 1
    error_message = "idle_report_retention_days must be at least 1."
  }
}
