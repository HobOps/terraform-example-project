# Targets shared by every stack: terraform/<stack>/Makefile includes this file.
# They run terraform through scripts/tf, which decrypts the state CSEK and
# loads bootstrap/config.env, so use them (or ../../scripts/tf) instead of
# calling terraform directly.

TF := ../../scripts/tf

.DEFAULT_GOAL := help
.PHONY: help init plan apply plan-destroy output clean

help: ## List the targets
	@grep -hE '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-13s %s\n", $$1, $$2}'

init: ## Initialize the encrypted GCS backend and the providers
	@$(TF) init

plan: ## Plan into ./tfplan (plaintext; `make apply` deletes it)
	@$(TF) plan -out=tfplan

apply: ## Apply ./tfplan, then delete it
	@$(TF) apply tfplan; status=$$?; rm -f tfplan; exit $$status

plan-destroy: ## Plan a destroy into ./tfplan; review it, then `make apply`
	@$(TF) plan -destroy -out=tfplan

output: ## Show the outputs
	@$(TF) output

clean: ## Delete .terraform/ and ./tfplan
	@rm -rf .terraform tfplan
