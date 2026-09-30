# Shared by every stack: terraform/<stack>/Makefile includes this file.
# Only `make init` needs make. Afterwards run terraform directly:
# terraform plan, terraform apply, terraform state list, ...

.DEFAULT_GOAL := help
.PHONY: help init clean

help: ## List the targets
	@grep -hE '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-6s %s\n", $$1, $$2}'

init: ## Decrypt the state CSEK to .terraform/csek, write config.auto.tfvars, terraform init
	@../../scripts/init $(ARGS)

clean: ## Delete .terraform/ (and the decrypted CSEK in it), config.auto.tfvars and tfplan
	@rm -rf .terraform config.auto.tfvars tfplan
