# Cost Anomaly Detection, Budgets, and the Cost Explorer APIs are global
# services fronted through us-east-1. Provision the cost-management resources
# in that partition regardless of where the rest of the estate runs.
provider "aws" {
  region = var.cost_management_region

  default_tags {
    tags = merge(
      {
        Project   = "aws-finops-automation"
        ManagedBy = "terraform"
        Component = "cost-management"
      },
      var.tags,
    )
  }
}
