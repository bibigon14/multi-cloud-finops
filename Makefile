PROJECT_ID := dstepanov-gke-platform
DATASET    := billing_export
BILLING_ID := 0108CD-97A262-B94181

.PHONY: help
help:
	@echo "Targets:"
	@echo "  init       - terraform init"
	@echo "  plan       - terraform plan"
	@echo "  apply      - terraform apply"
	@echo "  destroy    - terraform destroy (only removes the Grafana SA + IAM, not the dataset)"
	@echo "  tables     - list tables currently in the billing_export dataset"
	@echo "  mtd        - run the MTD-by-service reference query"
	@echo "  burn       - run the burn-rate reference query"
	@echo "  namespace  - run the cost-by-namespace query (needs Detailed export + GKE labels)"
	@echo "  focus      - run the FOCUS reference query"

.PHONY: init
init:
	cd terraform && terraform init

.PHONY: plan
plan:
	cd terraform && terraform plan

.PHONY: apply
apply:
	cd terraform && terraform apply

.PHONY: destroy
destroy:
	cd terraform && terraform destroy

.PHONY: tables
tables:
	bq ls --project_id=$(PROJECT_ID) $(DATASET)

.PHONY: mtd
mtd:
	bq query --project_id=$(PROJECT_ID) --use_legacy_sql=false --format=pretty < queries/mtd-by-service.sql

.PHONY: burn
burn:
	bq query --project_id=$(PROJECT_ID) --use_legacy_sql=false --format=pretty < queries/burn-rate.sql

.PHONY: namespace
namespace:
	bq query --project_id=$(PROJECT_ID) --use_legacy_sql=false --format=pretty < queries/cost-by-k8s-namespace.sql

.PHONY: focus
focus:
	bq query --project_id=$(PROJECT_ID) --use_legacy_sql=false --format=pretty < queries/focus-mtd.sql
