-- Highest-cost EC2 compute resources over the trailing 30 days.
--
-- Pairs with the Compute Optimizer rightsizing report: this view names the
-- resources burning the most money, and the report says how to shrink them.
-- Rendered by Terraform (${cur_table}, ${views_database}).
CREATE OR REPLACE VIEW ${views_database}.finops_top_compute_spend_by_resource AS
SELECT
    line_item_resource_id            AS resource_id,
    product_region                   AS region,
    line_item_usage_account_id       AS account_id,
    SUM(line_item_unblended_cost)    AS unblended_cost_30d
FROM ${cur_table}
WHERE line_item_line_item_type = 'Usage'
  AND line_item_product_code = 'AmazonEC2'
  AND line_item_resource_id <> ''
  AND line_item_usage_start_date >= date_add('day', -30, current_timestamp)
GROUP BY
    line_item_resource_id,
    product_region,
    line_item_usage_account_id
ORDER BY unblended_cost_30d DESC
LIMIT 100;
