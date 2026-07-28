-- Monthly cost grouped by the user-defined `environment` cost-allocation tag.
--
-- Untagged spend surfaces as 'untagged' so gaps in tag coverage are visible.
-- The `resource_tags_user_environment` column exists once the `environment`
-- cost-allocation tag is activated and appears in the CUR schema. Rendered by
-- Terraform (${cur_table}, ${views_database}).
CREATE OR REPLACE VIEW ${views_database}.finops_cost_by_environment_tag AS
SELECT
    date_trunc('month', line_item_usage_start_date) AS billing_month,
    COALESCE(
        NULLIF(resource_tags_user_environment, ''),
        'untagged'
    )                                               AS environment,
    SUM(line_item_unblended_cost)                   AS unblended_cost
FROM ${cur_table}
WHERE line_item_line_item_type = 'Usage'
GROUP BY
    date_trunc('month', line_item_usage_start_date),
    COALESCE(NULLIF(resource_tags_user_environment, ''), 'untagged');
