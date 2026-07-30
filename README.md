# aws-finops-automation

Cost visibility and optimization for AWS, delivered as Terraform. This project
codifies the guardrails that keep spend predictable — budgets, machine-learning
anomaly detection, rightsizing insight, idle-resource cleanup, and cost
reporting — so financial controls live in version control alongside the rest of
the platform.

## What this provisions

The initial capability set establishes the alerting backbone:

- **AWS Budgets** — an account-wide monthly cost budget with tiered
  actual-spend thresholds plus a forecasted-overrun alarm, and optional
  per-service budgets for the heaviest line items.
- **Cost Anomaly Detection** — a service-dimensional monitor over the whole
  account with an SNS subscription that fires only once an anomaly clears a
  configurable dollar-impact floor.
- **SNS alerting** — a single encrypted topic that both Budgets and Cost
  Anomaly Detection publish to, with email subscriptions and a least-privilege
  topic policy scoped to this account.

A Compute Optimizer **rightsizing report** collects EC2, Auto Scaling group,
EBS, and Lambda recommendations on a schedule, estimates the monthly savings,
and delivers a report to S3 and the alert topic. An **idle-resource finder**
reports unattached EBS volumes, unassociated Elastic IPs, and stale snapshots —
skipping anything tagged for retention — so reclaimable spend is surfaced
without deleting anything automatically. A set of **Athena cost views** turns
the Cost and Usage Report into analysis-ready views for spend trends and tag
allocation. Cost-allocation tag activation makes
user-defined tags billable dimensions in Cost Explorer and the CUR, and a
CloudWatch **cost dashboard** summarizes estimated charges in total, over time,
and per service.

## Layout

| Path             | Purpose                                                        |
| ---------------- | -------------------------------------------------------------- |
| `versions.tf`    | Terraform and provider version constraints.                    |
| `providers.tf`   | AWS provider pinned to the cost-management control-plane region. |
| `variables.tf`   | Input variables with validation.                               |
| `budgets.tf`     | Budgets, Cost Anomaly Detection, and the alert SNS topic.      |
| `outputs.tf`     | Topic ARN, budget names, anomaly and rightsizing/Athena refs.  |
| `rightsizing.tf` | Compute Optimizer report Lambda, report bucket, KMS, schedule. |
| `cleanup.tf`     | Idle-resource finder Lambda, report bucket, and schedule.      |
| `athena.tf`      | Athena workgroup, views database, and CUR cost-view queries.   |
| `allocation.tf`  | Cost-allocation tag activation for user-defined tag keys.       |
| `dashboard.tf`   | CloudWatch dashboard for total, trend, and per-service spend.   |
| `lambda/rightsizing/` | Rightsizing report generator source and its documentation. |
| `lambda/idle-finder/` | Idle-resource finder source and its documentation.         |
| `athena/`        | CUR cost-view SQL templates.                                   |

## Configuration

| Variable                          | Default       | Description                                             |
| --------------------------------- | ------------- | ------------------------------------------------------ |
| `cost_management_region`          | `us-east-1`   | Region for the cost-management control plane.          |
| `name_prefix`                     | `finops`      | Prefix for created resource names.                     |
| `monthly_budget_amount`           | `1000`        | Monthly cost ceiling in USD.                           |
| `budget_alert_thresholds_percent` | `[50,80,100]` | Percent-of-budget thresholds that raise an alert.      |
| `service_budgets`                 | `{}`          | Optional per-service monthly budgets.                  |
| `alert_email_addresses`           | `[]`          | Emails subscribed to the alert topic (confirm opt-in). |
| `enable_anomaly_detection`        | `true`        | Toggle the anomaly monitor and subscription.           |
| `anomaly_total_impact_threshold`  | `100`         | Minimum anomaly dollar impact before notifying.        |
| `enable_rightsizing_report`       | `true`        | Toggle the Compute Optimizer report Lambda.            |
| `rightsizing_schedule_expression` | weekly        | EventBridge schedule for the rightsizing report.       |
| `rightsizing_savings_threshold`   | `1`           | Minimum monthly USD savings shown in the report.       |
| `enable_idle_finder`              | `true`        | Toggle the idle-resource finder Lambda.                |
| `idle_finder_schedule_expression` | weekly        | EventBridge schedule for the idle-resource finder.     |
| `stale_snapshot_age_days`         | `90`          | Minimum snapshot age reported as stale.                |
| `idle_exclusion_tag_keys`         | `[finops:keep]` | Tag keys that exempt a resource from the report.     |
| `enable_athena_cost_views`        | `false`       | Register the Athena CUR cost views (needs a CUR table). |
| `cur_database_name` / `cur_table_name` | `null`   | Glue database/table of the Cost and Usage Report.      |
| `cost_allocation_tag_keys`        | `[Project, Environment, Team, CostCenter, Owner]` | Tag keys activated as cost-allocation tags. |
| `enable_cost_dashboard`           | `true`        | Toggle the CloudWatch cost dashboard.                  |
| `dashboard_service_dimensions`    | `[AmazonEC2, AmazonS3, AmazonRDS, AWSLambda, AmazonCloudWatch]` | Services charted on the per-service widget. |

## Quick start

```bash
terraform init
terraform plan \
  -var 'monthly_budget_amount=2500' \
  -var 'alert_email_addresses=["finops@example.invalid"]'
terraform apply
```

> All examples use placeholder values (account id `123456789012`,
> `example.invalid` addresses). Supply your own before applying. The
> configuration ships as templates and is never executed against a real
> account here.

## Design principles

- **Alerts route through one topic.** Budgets and anomaly detection share a
  single SNS topic, so notification wiring lives in one place.
- **Forecast before you overspend.** The highest budget threshold also arms a
  forecasted alarm to warn ahead of an actual overrun.
- **Least privilege by default.** The topic policy only lets the AWS
  cost-management services publish, and only from this account.
- **Everything is toggle-able.** Anomaly detection, the SNS topic, and each
  per-service budget can be turned on or off without editing the module.

## License

Released under the [MIT License](LICENSE).
