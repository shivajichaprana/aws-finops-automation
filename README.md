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

Subsequent capabilities layer on rightsizing reports from Compute Optimizer,
idle-resource discovery, cost-allocation tagging, and a spend dashboard.

## Layout

| Path             | Purpose                                                        |
| ---------------- | -------------------------------------------------------------- |
| `versions.tf`    | Terraform and provider version constraints.                    |
| `providers.tf`   | AWS provider pinned to the cost-management control-plane region. |
| `variables.tf`   | Input variables with validation.                               |
| `budgets.tf`     | Budgets, Cost Anomaly Detection, and the alert SNS topic.      |
| `outputs.tf`     | Topic ARN, budget names, and anomaly monitor/subscription ARNs. |

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
