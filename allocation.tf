###############################################################################
# Cost-allocation tagging
#
# Activating user-defined tag keys as cost-allocation tags lets spend be sliced
# by those keys in Cost Explorer, Budgets, and the Cost and Usage Report. This
# runs in the management (payer) account; activation takes effect once AWS has
# observed each tag on a billable resource, so newly activated keys populate on
# the next billing refresh rather than instantly.
###############################################################################

locals {
  cost_allocation_tag_keys = toset(var.cost_allocation_tag_keys)
}

resource "aws_ce_cost_allocation_tag" "user_defined" {
  for_each = local.cost_allocation_tag_keys

  tag_key = each.value
  status  = "Active"
}
