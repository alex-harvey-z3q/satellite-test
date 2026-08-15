SHELL := /bin/bash

TF_DIR := terraform
ANSIBLE_DIR := ansible
INSTALLER := scripts/install.sh

.DEFAULT_GOAL := help

.PHONY: help init fmt validate preflight configure plan apply install output ssh destroy

help: ## Show available targets.
	@awk 'BEGIN {FS = ":.*##"} /^[a-zA-Z_-]+:.*##/ {printf "\033[36m%-12s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

init: ## Download Terraform providers and initialise the working directory.
	terraform -chdir=$(TF_DIR) init

fmt: ## Format Terraform files.
	terraform -chdir=$(TF_DIR) fmt -recursive

validate: init ## Validate the Terraform configuration.
	terraform -chdir=$(TF_DIR) validate

preflight: validate ## Run Terraform validation and an Ansible syntax check.
	ANSIBLE_CONFIG=$(CURDIR)/$(ANSIBLE_DIR)/ansible.cfg ANSIBLE_LOCAL_TEMP=$(CURDIR)/$(ANSIBLE_DIR)/.ansible ansible-playbook --syntax-check -i 'localhost,' $(ANSIBLE_DIR)/site.yml

configure: ## Create the non-secret Ansible settings file when absent.
	@if [ -f $(ANSIBLE_DIR)/group_vars/all/main.yml ]; then \
		echo "$(ANSIBLE_DIR)/group_vars/all/main.yml already exists"; \
	else \
		cp $(ANSIBLE_DIR)/group_vars/all/main.yml.example $(ANSIBLE_DIR)/group_vars/all/main.yml; \
		echo "Created $(ANSIBLE_DIR)/group_vars/all/main.yml"; \
	fi

plan: preflight ## Show the proposed AWS changes.
	terraform -chdir=$(TF_DIR) plan -input=false

apply: preflight ## Create the AWS infrastructure (Terraform asks for confirmation).
	terraform -chdir=$(TF_DIR) apply

install: configure ## Install Satellite. Requires SSH_PRIVATE_KEY_FILE, RHSM_USERNAME, and RHSM_PASSWORD.
	@test -n "$(SSH_PRIVATE_KEY_FILE)" || (echo "Set SSH_PRIVATE_KEY_FILE to the private key for the EC2 key pair" >&2; exit 1)
	@test -n "$(RHSM_USERNAME)" || (echo "Set RHSM_USERNAME to your Red Hat login" >&2; exit 1)
	@test -n "$(RHSM_PASSWORD)" || (echo "Set RHSM_PASSWORD to your Red Hat password" >&2; exit 1)
	@SSH_PRIVATE_KEY_FILE="$(SSH_PRIVATE_KEY_FILE)" RHSM_USERNAME="$(RHSM_USERNAME)" RHSM_PASSWORD="$(RHSM_PASSWORD)" $(INSTALLER)

output: ## Show Terraform outputs, including the EC2 public IP and Satellite FQDN.
	terraform -chdir=$(TF_DIR) output

ssh: ## Open an SSH session. Requires SSH_PRIVATE_KEY_FILE.
	@test -n "$(SSH_PRIVATE_KEY_FILE)" || (echo "Set SSH_PRIVATE_KEY_FILE to the private key for the EC2 key pair" >&2; exit 1)
	ssh -i "$(SSH_PRIVATE_KEY_FILE)" ec2-user@$$(terraform -chdir=$(TF_DIR) output -raw public_ip)

destroy: ## Tear down the POC. Terraform asks for confirmation.
	terraform -chdir=$(TF_DIR) destroy
