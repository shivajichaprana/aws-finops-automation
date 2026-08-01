# Savings runbook

An operator playbook for turning the reports and alerts this platform produces
into realized savings. The automation only surfaces opportunities and never
deletes anything; every remediation below is an explicit, reviewed action.

## Where findings land

| Signal                   | Delivered to                                             |
| ------------------------ | -------------------------------------------------------- |
| Budget threshold crossed | Email via the cost-alert SNS topic                       |
| Cost anomaly detected    | Email via the cost-alert SNS topic                       |
| Rightsizing report       | S3 reports bucket (JSON) + summary to the SNS topic      |
| Idle-resource report     | S3 idle-reports bucket (JSON) + summary to the SNS topic |
| Spend attribution        | Athena cost views + the CloudWatch cost dashboard        |

Resolve the bucket and function names from the stack outputs:

```bash
terraform output rightsizing_report_bucket
terraform output idle_finder_report_bucket
terraform output cost_dashboard_name
```

## Lever 1 — right-size over-provisioned compute

The rightsizing report ranks EC2, Auto Scaling group, EBS, and Lambda
recommendations by estimated monthly savings.

1. Pull the latest report:
   ```bash
   BUCKET=$(terraform output -raw rightsizing_report_bucket)
   aws s3 cp "s3://$BUCKET/$(aws s3 ls "s3://$BUCKET/" --recursive \
     | sort | tail -1 | awk '{print $4}')" latest-rightsizing.json
   ```
2. Read `total_estimated_monthly_savings` and the per-resource entries. Each
   entry carries the current configuration, the recommended option, and the
   monthly saving.
3. For EC2 / ASG, confirm the recommended instance family covers peak CPU,
   memory, and network, then change the launch template or ASG and roll
   instances during a maintenance window.
4. For EBS, migrate `gp2` to `gp3` or reduce over-provisioned IOPS/throughput.
5. For Lambda, apply the recommended memory setting — it often improves both
   cost and latency.

Tune scope with `rightsizing_recommendation_rank` (1 conservative → 3
aggressive) and `rightsizing_savings_threshold` to hide low-value noise.

## Lever 2 — reclaim idle resources

The idle-resource report lists unattached EBS volumes, unassociated Elastic
IPs, and stale snapshots, each with an approximate monthly cost.

1. Pull the latest idle report from `idle_finder_report_bucket` (same pattern
   as above).
2. **Confirm each item is truly disposable.** An unattached volume may hold data
   pending a restore; a stale snapshot may be a retention artifact.
3. Protect anything that must stay by adding a retention tag — by default any
   resource tagged `finops:keep` is excluded from future reports. Add more keys
   via `idle_exclusion_tag_keys`.
4. For confirmed waste, remediate manually and deliberately:
   ```bash
   # Snapshot a volume before deleting, then remove it
   aws ec2 create-snapshot --volume-id vol-0123456789abcdef0 \
     --description "pre-delete backup"
   aws ec2 delete-volume --volume-id vol-0123456789abcdef0

   # Release an unassociated Elastic IP
   aws ec2 release-address --allocation-id eipalloc-0123456789abcdef0

   # Delete a confirmed-stale snapshot
   aws ec2 delete-snapshot --snapshot-id snap-0123456789abcdef0
   ```
5. Set `orphaned_snapshots_only = true` to narrow the snapshot report to those
   whose source volume no longer exists, and raise `stale_snapshot_age_days` to
   match your retention policy.

## Lever 3 — respond to a cost anomaly

When an anomaly email arrives:

1. Open Cost Explorer and group the impacted service by usage type and by the
   activated cost-allocation tags to localize the driver.
2. Distinguish a legitimate change (a launch, a backfill) from a regression (a
   runaway job, a forgotten test fleet, a misconfigured log retention).
3. If it is a regression, remediate at the source; if it is expected, note it so
   the team reading the alert has context.
4. If normal spend routinely trips the alert, raise
   `anomaly_total_impact_threshold` so the signal stays meaningful.

## Lever 4 — stay ahead of the budget

Budget alerts arrive at 50/80/100 percent of the monthly ceiling by default,
and the top threshold also forecasts an overrun.

1. On a **forecasted** alert, act before month-end — the account is trending
   over. Combine levers 1 and 2, and review the anomaly and dashboard views.
2. On an **actual** 100 percent alert, the ceiling is already reached; confirm
   whether the budget itself needs to grow (via `monthly_budget_amount`) or
   spend needs to come down.
3. Add per-service budgets through `service_budgets` for the heaviest line
   items so a single service overrunning is visible on its own.

## Lever 5 — attribute spend so teams own it

1. Ensure every billable resource carries the tags in
   `cost_allocation_tag_keys` (`Project`, `Environment`, `Team`, `CostCenter`,
   `Owner` by default). Enforce this upstream in your provisioning pipeline.
2. Query the Athena `cost_by_environment_tag` view (enable
   `enable_athena_cost_views` with a CUR table) to break spend down by tag.
3. Watch the CloudWatch cost dashboard for total, trend, and per-service spend
   between the deeper Cost Explorer reviews.
4. Where a large share shows up as untagged, close the tagging gap — untagged
   spend cannot be attributed or optimized by owner.

## Cadence

- **Weekly:** review the rightsizing and idle reports; act on the top savings.
- **On alert:** respond to anomaly and forecasted-budget emails promptly.
- **Monthly:** review budget outcomes and per-tag attribution; adjust budgets,
  thresholds, and exclusion tags for the next cycle.
