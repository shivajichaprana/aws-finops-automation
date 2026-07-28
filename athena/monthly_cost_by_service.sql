-- Monthly unblended cost by AWS service.
--
-- Aggregates the Cost and Usage Report (CUR) into a per-month, per-service
-- spend view. Usage line items only (credits, refunds, and taxes excluded) so
-- the figures track consumption. Rendered by Terraform: ${cur_table} is the
-- fully-qualified CUR table and ${views_database} is where the view lands.
CREATE OR REPLACE VIEW ${views_database}.finops_monthly_cost_by_service AS
SELECT
    date_trunc('month', line_item_usage_start_date)        AS billing_month,
    line_item_usage_account_id                             AS account_id,
    product_product_name                                   AS service,
    SUM(line_item_unblended_cost)                          AS unblended_cost,
    SUM(line_item_usage_amount)                            AS usage_amount
FROM ${cur_table}
WHERE line_item_line_item_type = 'Usage'
GROUP BY
    date_trunc('month', line_item_usage_start_date),
    line_item_usage_account_id,
    product_product_name;
