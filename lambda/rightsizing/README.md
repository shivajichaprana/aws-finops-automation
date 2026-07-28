# Rightsizing report Lambda

Generates an account-wide rightsizing report from AWS Compute Optimizer and
delivers it to S3 and (optionally) SNS.

## What it does

On each invocation the function reads Compute Optimizer recommendations for:

- EC2 instances (overprovisioned instances that can move to a smaller type)
- Auto Scaling groups (overprovisioned launch instance types)
- EBS volumes (non-optimal volume types, e.g. `gp2` to `gp3`)
- Lambda functions (over-allocated memory)

For each family it keeps recommendations whose estimated monthly savings clear
a configurable floor, sorts them by savings, tallies per-family and total
savings, then writes a date-partitioned JSON report to S3 and publishes a short
text summary to the alert topic.

The function is strictly read-only against the account. It never resizes,
stops, or deletes a resource — it produces recommendations for an operator to
review and apply through the normal change process.

## Configuration

Configuration is entirely through environment variables:

| Variable              | Required | Default          | Purpose                                            |
| --------------------- | -------- | ---------------- | -------------------------------------------------- |
| `REPORT_BUCKET`       | yes      | —                | S3 bucket the JSON report is written to.           |
| `REPORT_PREFIX`       | no       | `rightsizing/`   | Key prefix for reports.                            |
| `SNS_TOPIC_ARN`       | no       | (unset)          | Topic the summary is published to; empty skips.    |
| `SAVINGS_THRESHOLD`   | no       | `1`              | Minimum estimated monthly USD savings to include.  |
| `RECOMMENDATION_RANK` | no       | `1`              | Compute Optimizer option rank (1 conservative–3).  |
| `LOG_LEVEL`           | no       | `INFO`           | Python log level.                                  |

## Report shape

```json
{
  "generated_at": "2020-01-01T00:00:00+00:00",
  "recommendation_rank": 1,
  "savings_threshold": 1.0,
  "total_estimated_monthly_savings": 0.0,
  "resource_count": 0,
  "by_resource_type": {
    "EC2Instance": { "count": 0, "estimated_monthly_savings": 0.0 }
  },
  "recommendations": []
}
```

## Prerequisites

Compute Optimizer must be opted in for the account (or organization) before it
has recommendations to serve. This project provisions the collector, IAM role,
schedule, and report bucket; enabling Compute Optimizer itself is an
account-level action taken outside this template.
