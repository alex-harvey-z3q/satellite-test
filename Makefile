SHELL := /bin/bash

TF_DIR := terraform
ANSIBLE_DIR := ansible
INSTALLER := scripts/install.sh
FOREMAN_ACCEPTANCE_HOST_PAYLOAD_FILE ?= $(CURDIR)/spec/fixtures/foreman-acceptance-host.json

TERRAFORM := terraform -chdir=$(TF_DIR)
tf_output = $(TERRAFORM) output -raw $(1)
ANSIBLE_PLAYBOOK := ANSIBLE_CONFIG=$(CURDIR)/$(ANSIBLE_DIR)/ansible.cfg ANSIBLE_LOCAL_TEMP=$(CURDIR)/$(ANSIBLE_DIR)/.ansible ansible-playbook
ANSIBLE_REMOTE_ARGS = --user ec2-user --private-key "$(SSH_PRIVATE_KEY_FILE)" --ssh-common-args="-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$(CURDIR)/$(ANSIBLE_DIR)/.ansible/known_hosts"

define require_ssh_private_key
@test -n "$(SSH_PRIVATE_KEY_FILE)" || (echo "Set SSH_PRIVATE_KEY_FILE to the private key for the EC2 key pair" >&2; exit 1)
endef

define require_foreman_credentials
@test -n "$${FOREMAN_USER:-}" || (echo "Export FOREMAN_USER for a Satellite API user" >&2; exit 1)
@test -n "$${FOREMAN_PASSWORD:-}" || (echo "Export FOREMAN_PASSWORD for that user's password" >&2; exit 1)
endef

.DEFAULT_GOAL := help

.PHONY: help init fmt validate preflight configure plan apply update-my-ip install output ssh destroy hammer satellite-installer answer-service templates test-setup acceptance-fixture test-contract test-acceptance

help: ## Show available targets.
	@awk 'BEGIN {FS = ":.*##"} /^[a-zA-Z_-]+:.*##/ {printf "\033[36m%-12s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

init: ## Download Terraform providers and initialise the working directory.
	$(TERRAFORM) init

fmt: ## Format Terraform files.
	$(TERRAFORM) fmt -recursive

validate: init ## Validate the Terraform configuration.
	$(TERRAFORM) validate

preflight: validate ## Run Terraform validation and an Ansible syntax check.
	$(ANSIBLE_PLAYBOOK) --syntax-check -i 'localhost,' $(ANSIBLE_DIR)/site.yml
	$(ANSIBLE_PLAYBOOK) --syntax-check -i 'localhost,' $(ANSIBLE_DIR)/proxmox/hammer.yml
	$(ANSIBLE_PLAYBOOK) --syntax-check -i 'localhost,' $(ANSIBLE_DIR)/proxmox/satellite_installer.yml
	$(ANSIBLE_PLAYBOOK) --syntax-check -i 'localhost,' $(ANSIBLE_DIR)/proxmox/answer_service.yml
	$(ANSIBLE_PLAYBOOK) --syntax-check -i 'localhost,' $(ANSIBLE_DIR)/proxmox/templates.yml

configure: ## Create the non-secret Ansible settings file when absent.
	@if [ -f $(ANSIBLE_DIR)/group_vars/all/main.yml ]; then \
		echo "$(ANSIBLE_DIR)/group_vars/all/main.yml already exists"; \
	else \
		cp $(ANSIBLE_DIR)/group_vars/all/main.yml.example $(ANSIBLE_DIR)/group_vars/all/main.yml; \
		echo "Created $(ANSIBLE_DIR)/group_vars/all/main.yml"; \
	fi

plan: preflight ## Show the proposed AWS changes.
	$(TERRAFORM) plan -input=false

apply: preflight ## Create the AWS infrastructure (Terraform asks for confirmation).
	$(TERRAFORM) apply -auto-approve

update-my-ip: ## Detect the current public IPv4, update SSH/HTTPS CIDRs, then apply Terraform.
	@test -f $(TF_DIR)/terraform.tfvars || (echo "Create $(TF_DIR)/terraform.tfvars before updating access CIDRs" >&2; exit 1)
	@public_ip="$$(curl --fail --silent --show-error https://checkip.amazonaws.com | tr -d '\n')"; \
	[[ "$$public_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$$ ]] || (echo "Could not determine a public IPv4 address" >&2; exit 1); \
	ruby scripts/update-access-cidrs.rb $(TF_DIR)/terraform.tfvars "$$public_ip"; \
	echo "Updated SSH and HTTPS access CIDRs to $$public_ip/32"
	$(MAKE) apply

install: configure ## Install base Satellite. Requires SSH_PRIVATE_KEY_FILE, RHSM_USERNAME, and RHSM_PASSWORD.
	$(require_ssh_private_key)
	@test -n "$(RHSM_USERNAME)" || (echo "Set RHSM_USERNAME to your Red Hat login" >&2; exit 1)
	@test -n "$(RHSM_PASSWORD)" || (echo "Set RHSM_PASSWORD to your Red Hat password" >&2; exit 1)
	@SSH_PRIVATE_KEY_FILE="$(SSH_PRIVATE_KEY_FILE)" RHSM_USERNAME="$(RHSM_USERNAME)" RHSM_PASSWORD="$(RHSM_PASSWORD)" $(INSTALLER)

output: ## Show Terraform outputs, including the EC2 public IP and Satellite FQDN.
	$(TERRAFORM) output

ssh: ## Open an SSH session. Requires SSH_PRIVATE_KEY_FILE.
	$(require_ssh_private_key)
	ssh -i "$(SSH_PRIVATE_KEY_FILE)" ec2-user@$$($(call tf_output,public_ip))

destroy: ## Tear down the POC. Terraform asks for confirmation.
	$(TERRAFORM) destroy

satellite-installer: ## Apply the POC-specific Apache route through Satellite Installer.
	$(require_ssh_private_key)
	@$(ANSIBLE_PLAYBOOK) \
		-i "$$($(call tf_output,public_ip))," \
		$(ANSIBLE_REMOTE_ARGS) \
		$(ANSIBLE_DIR)/proxmox/satellite_installer.yml

answer-service: ## Install the POC-specific answer-adapter service.
	$(require_ssh_private_key)
	@$(ANSIBLE_PLAYBOOK) \
		-i "$$($(call tf_output,public_ip))," \
		$(ANSIBLE_REMOTE_ARGS) \
		$(ANSIBLE_DIR)/proxmox/answer_service.yml

hammer: ## Create Foreman test objects using Terraform's dedicated provisioning subnet.
	$(require_ssh_private_key)
	@set -e; subnet_name="$$($(call tf_output,provisioning_subnet_name))"; \
	$(ANSIBLE_PLAYBOOK) \
		-i "$$($(call tf_output,public_ip))," \
		$(ANSIBLE_DIR)/proxmox/hammer.yml \
		$(ANSIBLE_REMOTE_ARGS) \
		-e 'proxmox_prerequisites_apply=true' \
		-e 'proxmox_allow_routable_test_subnet=true' \
		-e "proxmox_test_subnet_name=$$subnet_name" \
		-e "proxmox_test_subnet_network=$$($(call tf_output,provisioning_subnet_network))" \
		-e "proxmox_test_subnet_mask=$$($(call tf_output,provisioning_subnet_mask))" \
		-e "proxmox_test_subnet_gateway=$$($(call tf_output,provisioning_subnet_gateway))" \
		-e "proxmox_test_subnet_dns=$$($(call tf_output,provisioning_subnet_dns))" \
		-e "proxmox_test_dhcp_proxy=$$($(call tf_output,satellite_fqdn))" \
		-e "proxmox_test_acceptance_ip=$$($(call tf_output,provisioning_acceptance_test_ip))"

templates: ## Deploy the POC answer and iPXE templates through Hammer.
	$(require_ssh_private_key)
	@$(ANSIBLE_PLAYBOOK) \
		-i "$$($(call tf_output,public_ip))," \
		$(ANSIBLE_REMOTE_ARGS) \
		-e "proxmox_foreman_fqdn=$$($(call tf_output,satellite_fqdn))" \
		$(ANSIBLE_DIR)/proxmox/templates.yml

test-setup: ## Install the Ruby dependencies used by the Serverspec suites.
	bundle install

acceptance-fixture: ## Create the ignored Foreman API test-host payload when absent.
	@test ! -e spec/fixtures/foreman-acceptance-host.json || (echo "spec/fixtures/foreman-acceptance-host.json already exists" >&2; exit 1)
	cp spec/fixtures/foreman-acceptance-host.json.example spec/fixtures/foreman-acceptance-host.json

test-contract: test-setup ## Run safe Proxmox answer-adapter contract checks. Requires SSH_PRIVATE_KEY_FILE.
	$(require_ssh_private_key)
	@TARGET_HOST="$$($(call tf_output,public_ip))" SSH_PRIVATE_KEY_FILE="$(SSH_PRIVATE_KEY_FILE)" SATELLITE_FQDN="$$($(call tf_output,satellite_fqdn))" PROVISIONING_SUBNET_NAME="$$($(call tf_output,provisioning_subnet_name))" PROVISIONING_SUBNET_CIDR="$$($(call tf_output,provisioning_subnet_cidr))" bundle exec rspec spec/proxmox_deployment_spec.rb spec/proxmox_foreman_contract_spec.rb

test-acceptance: test-setup ## Create, validate, and delete an opt-in Foreman API test host. Requires FOREMAN_USER and FOREMAN_PASSWORD.
	$(require_ssh_private_key)
	@test -f "$(FOREMAN_ACCEPTANCE_HOST_PAYLOAD_FILE)" || (echo "Run 'make acceptance-fixture', then edit $(FOREMAN_ACCEPTANCE_HOST_PAYLOAD_FILE) with this Satellite's IDs" >&2; exit 1)
	@! rg -q 'REPLACE_WITH_' "$(FOREMAN_ACCEPTANCE_HOST_PAYLOAD_FILE)" || (echo "Replace every REPLACE_WITH_* value in $(FOREMAN_ACCEPTANCE_HOST_PAYLOAD_FILE) before running the acceptance test" >&2; exit 1)
	$(require_foreman_credentials)
	@TARGET_HOST="$$($(call tf_output,public_ip))" SSH_PRIVATE_KEY_FILE="$(SSH_PRIVATE_KEY_FILE)" FOREMAN_ACCEPTANCE_HOST_PAYLOAD_FILE="$(FOREMAN_ACCEPTANCE_HOST_PAYLOAD_FILE)" FOREMAN_API_USERNAME="$${FOREMAN_USER}" FOREMAN_API_PASSWORD="$${FOREMAN_PASSWORD}" RUN_FOREMAN_ACCEPTANCE=true bundle exec rspec spec/proxmox_foreman_acceptance_spec.rb
