# aws-finops-automation --- operator entry points.
# Validation targets mirror the checks enforced in continuous integration.

PY_FILES := $(shell git ls-files "*.py")

.DEFAULT_GOAL := help

.PHONY: help init fmt fmt-check validate lint test plan deploy report destroy clean

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| sort \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

init: ## Initialize Terraform without a backend
	terraform init -backend=false -input=false

fmt: ## Format Terraform files in place
	terraform fmt -recursive

fmt-check: ## Check Terraform formatting (no changes)
	terraform fmt -check -diff -recursive

validate: fmt-check ## Format-check, init, and validate the configuration
	terraform init -backend=false -input=false
	terraform validate

lint: ## Run TFLint (fails on error severity)
	tflint --init
	tflint --minimum-failure-severity=error

test: ## Run the Python unit tests for both report Lambdas
	flake8 --select=E9,F63,F7,F82 --show-source lambda/ tests/
	python -m py_compile $(PY_FILES)
	pytest tests/ -q

plan: ## Show the Terraform execution plan
	terraform plan

deploy: ## Apply the configuration (supply -var overrides as needed)
	terraform apply

report: ## Invoke the report Lambdas on demand and save their responses
	@set -euo pipefail; \
		RS=$$(terraform output -raw rightsizing_function_name 2>/dev/null || true); \
		ID=$$(terraform output -raw idle_finder_function_name 2>/dev/null || true); \
		if [ -n "$$RS" ]; then \
			echo "Invoking rightsizing report: $$RS"; \
			aws lambda invoke --function-name "$$RS" rightsizing-response.json >/dev/null; \
		fi; \
		if [ -n "$$ID" ]; then \
			echo "Invoking idle-resource finder: $$ID"; \
			aws lambda invoke --function-name "$$ID" idle-response.json >/dev/null; \
		fi; \
		echo "Reports written to the configured S3 buckets; responses saved locally."

destroy: ## Tear down the configuration
	terraform destroy

clean: ## Remove local Terraform and invocation artifacts
	rm -rf .terraform .terraform.lock.hcl *.tfplan *-response.json
