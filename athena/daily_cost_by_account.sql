-- Daily unblended cost by linked account.
--
-- Drives day-over-day spend trend lines and feeds the cost dashboard. Usage
-- line items only. Rendered by Terraform (${cur_table}, ${views_database}).
CREATE OR REPLACE VIEW ${views_database}.finops_daily_cost_by_account AS
SELECT
    date_trunc('day', line_item_usage_start_date) AS billing_day,
    line_item_usage_account_id                    AS account_id,
    SUM(line_item_unblended_cost)                 AS unblended_cost
FROM ${cur_table}
WHERE line_item_line_item_type = 'Usage'
GROUP BY
    date_trunc('day', line_item_usage_start_date),
    line_item_usage_account_id;
