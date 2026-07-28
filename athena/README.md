# Athena cost views over the CUR

SQL view definitions that turn the AWS Cost and Usage Report (CUR) into a small
set of analysis-ready views. The rightsizing report Lambda answers "what should
I resize"; these views answer "where is the money going".

## Views

| File                              | View                                       | Grain                          |
| --------------------------------- | ------------------------------------------ | ------------------------------ |
| `monthly_cost_by_service.sql`     | `finops_monthly_cost_by_service`           | month × account × service      |
| `daily_cost_by_account.sql`       | `finops_daily_cost_by_account`             | day × account                  |
| `cost_by_environment_tag.sql`     | `finops_cost_by_environment_tag`           | month × `environment` tag      |
| `top_compute_spend_by_resource.sql` | `finops_top_compute_spend_by_resource`   | EC2 resource, trailing 30 days |

## Templating

Each file is a Terraform template rendered at apply time. Two placeholders are
substituted:

- `${cur_table}` — the fully-qualified CUR table, e.g. `cur_db.cur_table`.
- `${views_database}` — the Glue/Athena database the views are created in.

The rendered statements are registered as Athena named queries (see
`athena.tf`) so they can be run from the Athena console or the CLI without
copy-paste. Provisioning the views is gated behind `enable_athena_cost_views`
because it depends on a CUR table that already exists in the account.

## Prerequisites

- A Cost and Usage Report delivered to S3 and catalogued as a Glue table
  (via the CUR-provided crawler or an AWS Glue table). Set `cur_database_name`
  and `cur_table_name` to point at it.
- Cost-allocation tags (for example `environment`) activated in the Billing
  console so their `resource_tags_user_*` columns appear in the CUR schema.

All identifiers in examples are placeholders; substitute your own CUR database
and table names before applying.
