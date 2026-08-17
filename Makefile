SHELL := /bin/bash

TF_DIR := terraform
ANSIBLE_DIR := ansible
INSTALLER := scripts/install.sh
FOREMAN_ACCEPTANCE_HOST_PAYLOAD_FILE ?= $(CURDIR)/spec/fixtures/foreman-acceptance-host.json

.DEFAULT_GOAL := help

.PHONY: help init fmt validate preflight configure plan apply update-my-ip install output ssh destroy proxmox-answer proxmox-prerequisites proxmox-templates proxmox-test-bootstrap proxmox-dhcp proxmox-deploy test-setup acceptance-fixture test-contract test-acceptance

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
	ANSIBLE_CONFIG=$(CURDIR)/$(ANSIBLE_DIR)/ansible.cfg ANSIBLE_LOCAL_TEMP=$(CURDIR)/$(ANSIBLE_DIR)/.ansible ansible-playbook --syntax-check -i 'localhost,' $(ANSIBLE_DIR)/proxmox_prerequisites.yml

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

update-my-ip: ## Detect the current public IPv4, update SSH/HTTPS CIDRs, then apply Terraform.
	@test -f $(TF_DIR)/terraform.tfvars || (echo "Create $(TF_DIR)/terraform.tfvars before updating access CIDRs" >&2; exit 1)
	@public_ip="$$(curl --fail --silent --show-error https://checkip.amazonaws.com | tr -d '\n')"; \
	[[ "$$public_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$$ ]] || (echo "Could not determine a public IPv4 address" >&2; exit 1); \
	PUBLIC_IP="$$public_ip" ruby -e 'path = ARGV.fetch(0); content = File.read(path); ip = ENV.fetch("PUBLIC_IP"); %w[admin_cidrs ssh_cidrs].each { |key| pattern = /^(\s*#{Regexp.escape(key)}\s*=\s*)\[[^\]]*\]/; raise "Missing #{key} in terraform.tfvars" unless content.match?(pattern); content.sub!(pattern) { "#{$$1}[\"#{ip}/32\"]" } }; File.write(path, content)' $(TF_DIR)/terraform.tfvars; \
	echo "Updated SSH and HTTPS access CIDRs to $$public_ip/32"
	$(MAKE) apply

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

proxmox-answer: ## Deploy the Proxmox answer adapter. Requires SSH_PRIVATE_KEY_FILE.
	@test -n "$(SSH_PRIVATE_KEY_FILE)" || (echo "Set SSH_PRIVATE_KEY_FILE to the private key for the EC2 key pair" >&2; exit 1)
	@host="$$(terraform -chdir=$(TF_DIR) output -raw public_ip)"; \
	ssh() { command ssh -i "$(SSH_PRIVATE_KEY_FILE)" -o StrictHostKeyChecking=accept-new -o User=ec2-user "$$@"; }; \
	scp() { command scp -i "$(SSH_PRIVATE_KEY_FILE)" -o StrictHostKeyChecking=accept-new -o User=ec2-user "$$@"; }; \
	export -f ssh scp; \
	FOREMAN_FQDN="$$host" bash proxmox/scripts/deploy-proxmox-foreman-answer.sh --apply

proxmox-prerequisites: ## Create Foreman test objects using Terraform's dedicated provisioning subnet.
	@test -n "$(SSH_PRIVATE_KEY_FILE)" || (echo "Set SSH_PRIVATE_KEY_FILE to the private key for the EC2 key pair" >&2; exit 1)
	@subnet_name="$$(terraform -chdir=$(TF_DIR) output -raw provisioning_subnet_name)"; \
	ANSIBLE_CONFIG="$(CURDIR)/$(ANSIBLE_DIR)/ansible.cfg" ANSIBLE_LOCAL_TEMP="$(CURDIR)/$(ANSIBLE_DIR)/.ansible" ansible-playbook \
		-i "$$(terraform -chdir=$(TF_DIR) output -raw public_ip)," \
		$(ANSIBLE_DIR)/proxmox_prerequisites.yml \
		--user ec2-user \
		--private-key "$(SSH_PRIVATE_KEY_FILE)" \
		--ssh-common-args="-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$(CURDIR)/$(ANSIBLE_DIR)/.ansible/known_hosts" \
		-e 'proxmox_prerequisites_apply=true' \
		-e 'proxmox_allow_routable_test_subnet=true' \
		-e "proxmox_test_subnet_name=$$subnet_name" \
		-e "proxmox_test_subnet_network=$$(terraform -chdir=$(TF_DIR) output -raw provisioning_subnet_network)" \
		-e "proxmox_test_subnet_mask=$$(terraform -chdir=$(TF_DIR) output -raw provisioning_subnet_mask)" \
		-e "proxmox_test_subnet_gateway=$$(terraform -chdir=$(TF_DIR) output -raw provisioning_subnet_gateway)" \
		-e "proxmox_test_subnet_dns=$$(terraform -chdir=$(TF_DIR) output -raw provisioning_subnet_dns)"

proxmox-templates: ## Update Proxmox Foreman templates. Requires SSH_PRIVATE_KEY_FILE, FOREMAN_USER, and FOREMAN_PASSWORD.
	@test -n "$(SSH_PRIVATE_KEY_FILE)" || (echo "Set SSH_PRIVATE_KEY_FILE to the private key for the EC2 key pair" >&2; exit 1)
	@test -n "$${FOREMAN_USER:-}" || (echo "Export FOREMAN_USER for a Satellite API user" >&2; exit 1)
	@test -n "$${FOREMAN_PASSWORD:-}" || (echo "Export FOREMAN_PASSWORD for that user's password" >&2; exit 1)
	@! rg -q 'REPLACE_WITH_FOREMAN_FQDN' proxmox/assets/ipxe/autoexec.ipxe proxmox/erb/ipxe.erb || (echo "Replace REPLACE_WITH_FOREMAN_FQDN in the Proxmox iPXE assets before deploying templates" >&2; exit 1)
	@host="$$(terraform -chdir=$(TF_DIR) output -raw public_ip)"; \
	fqdn="$$(terraform -chdir=$(TF_DIR) output -raw satellite_fqdn)"; \
	local_dir="$$(mktemp -d)"; \
	trap 'rm -rf "$$local_dir"' EXIT; \
	env_file="$$local_dir/foreman.env"; \
	remote_dir="/tmp/proxmox-templates-$$$$"; \
	(umask 077; printf 'FOREMAN_FQDN=%q\nFOREMAN_USER=%q\nFOREMAN_PASSWORD=%q\n' "$$fqdn" "$${FOREMAN_USER}" "$${FOREMAN_PASSWORD}" > "$$env_file"); \
	ssh -i "$(SSH_PRIVATE_KEY_FILE)" -o StrictHostKeyChecking=accept-new ec2-user@"$$host" "mkdir -p '$$remote_dir'"; \
	scp -i "$(SSH_PRIVATE_KEY_FILE)" -o StrictHostKeyChecking=accept-new -r proxmox/assets proxmox/erb proxmox/scripts "$$env_file" ec2-user@"$$host":"$$remote_dir/"; \
	ssh -tt -i "$(SSH_PRIVATE_KEY_FILE)" -o StrictHostKeyChecking=accept-new ec2-user@"$$host" "set -e; . '$$remote_dir/foreman.env'; rm -f '$$remote_dir/foreman.env'; bash '$$remote_dir/scripts/deploy-proxmox-foreman-templates.sh' --apply"; \
	ssh -i "$(SSH_PRIVATE_KEY_FILE)" -o StrictHostKeyChecking=accept-new ec2-user@"$$host" "rm -rf '$$remote_dir'"

proxmox-test-bootstrap: ## Create test records, update templates, and deploy the adapter without DHCP changes.
	$(MAKE) proxmox-prerequisites SSH_PRIVATE_KEY_FILE="$(SSH_PRIVATE_KEY_FILE)"
	$(MAKE) proxmox-templates SSH_PRIVATE_KEY_FILE="$(SSH_PRIVATE_KEY_FILE)"
	$(MAKE) proxmox-answer SSH_PRIVATE_KEY_FILE="$(SSH_PRIVATE_KEY_FILE)"

proxmox-dhcp: ## Configure DHCP/TFTP/iPXE and assign its proxy to the provisioning subnet. Requires SSH_PRIVATE_KEY_FILE, FOREMAN_USER, FOREMAN_PASSWORD, and PVE_DHCP_OMAPI_SECRET.
	@test -n "$(SSH_PRIVATE_KEY_FILE)" || (echo "Set SSH_PRIVATE_KEY_FILE to the private key for the EC2 key pair" >&2; exit 1)
	@test -n "$${PVE_DHCP_OMAPI_SECRET:-}" || (echo "Export PVE_DHCP_OMAPI_SECRET" >&2; exit 1)
	@test -n "$${FOREMAN_USER:-}" || (echo "Export FOREMAN_USER for a Satellite API user" >&2; exit 1)
	@test -n "$${FOREMAN_PASSWORD:-}" || (echo "Export FOREMAN_PASSWORD for that user's password" >&2; exit 1)
	@host="$$(terraform -chdir=$(TF_DIR) output -raw public_ip)"; \
	fqdn="$$(terraform -chdir=$(TF_DIR) output -raw satellite_fqdn)"; \
	subnet_cidr="$$(terraform -chdir=$(TF_DIR) output -raw provisioning_subnet_cidr)"; \
	subnet_name="$$(terraform -chdir=$(TF_DIR) output -raw provisioning_subnet_name)"; \
	local_dir="$$(mktemp -d)"; \
	trap 'rm -rf "$$local_dir"' EXIT; \
	env_file="$$local_dir/foreman.env"; \
	remote_dir="/tmp/proxmox-foreman-dhcp-$$$$"; \
	ssh() { command ssh -i "$(SSH_PRIVATE_KEY_FILE)" -o StrictHostKeyChecking=accept-new -o User=ec2-user "$$@"; }; \
	scp() { command scp -i "$(SSH_PRIVATE_KEY_FILE)" -o StrictHostKeyChecking=accept-new -o User=ec2-user "$$@"; }; \
	export -f ssh scp; \
	FOREMAN_FQDN="$$host" PROVISIONING_SUBNET_CIDR="$$subnet_cidr" PVE_DHCP_OMAPI_SECRET="$${PVE_DHCP_OMAPI_SECRET}" bash proxmox/scripts/configure-foreman-ipxe-dhcp.sh --apply; \
	(umask 077; printf 'FOREMAN_FQDN=%q\nFOREMAN_USER=%q\nFOREMAN_PASSWORD=%q\n' "$$fqdn" "$${FOREMAN_USER}" "$${FOREMAN_PASSWORD}" > "$$env_file"); \
	ssh ec2-user@"$$host" "mkdir -p '$$remote_dir'"; \
	scp proxmox/scripts/configure-foreman-ipxe-dhcp.sh "$$env_file" ec2-user@"$$host":"$$remote_dir/"; \
	ssh -tt ec2-user@"$$host" "set -e; . '$$remote_dir/foreman.env'; rm -f '$$remote_dir/foreman.env'; bash '$$remote_dir/configure-foreman-ipxe-dhcp.sh' --configure-foreman --subnet '$$subnet_name'; rm -rf '$$remote_dir'"

proxmox-deploy: ## Run Proxmox prerequisites and all three supplied Bash deployers in dependency order.
	$(MAKE) proxmox-prerequisites SSH_PRIVATE_KEY_FILE="$(SSH_PRIVATE_KEY_FILE)"
	$(MAKE) proxmox-dhcp SSH_PRIVATE_KEY_FILE="$(SSH_PRIVATE_KEY_FILE)"
	$(MAKE) proxmox-templates SSH_PRIVATE_KEY_FILE="$(SSH_PRIVATE_KEY_FILE)"
	$(MAKE) proxmox-answer SSH_PRIVATE_KEY_FILE="$(SSH_PRIVATE_KEY_FILE)"

test-setup: ## Install the Ruby dependencies used by the Serverspec suites.
	bundle install

acceptance-fixture: ## Create the ignored Foreman API test-host payload when absent.
	@test ! -e spec/fixtures/foreman-acceptance-host.json || (echo "spec/fixtures/foreman-acceptance-host.json already exists" >&2; exit 1)
	cp spec/fixtures/foreman-acceptance-host.json.example spec/fixtures/foreman-acceptance-host.json

test-contract: test-setup ## Run safe Proxmox answer-adapter contract checks. Requires SSH_PRIVATE_KEY_FILE.
	@test -n "$(SSH_PRIVATE_KEY_FILE)" || (echo "Set SSH_PRIVATE_KEY_FILE to the private key for the EC2 key pair" >&2; exit 1)
	@TARGET_HOST="$$(terraform -chdir=$(TF_DIR) output -raw public_ip)" SSH_PRIVATE_KEY_FILE="$(SSH_PRIVATE_KEY_FILE)" bundle exec rspec spec/proxmox_foreman_contract_spec.rb

test-acceptance: test-setup ## Create, validate, and delete an opt-in Foreman API test host. Requires its documented environment variables.
	@test -n "$(SSH_PRIVATE_KEY_FILE)" || (echo "Set SSH_PRIVATE_KEY_FILE to the private key for the EC2 key pair" >&2; exit 1)
	@test -f "$(FOREMAN_ACCEPTANCE_HOST_PAYLOAD_FILE)" || (echo "Run 'make acceptance-fixture', then edit $(FOREMAN_ACCEPTANCE_HOST_PAYLOAD_FILE) with this Satellite's IDs" >&2; exit 1)
	@! rg -q 'REPLACE_WITH_' "$(FOREMAN_ACCEPTANCE_HOST_PAYLOAD_FILE)" || (echo "Replace every REPLACE_WITH_* value in $(FOREMAN_ACCEPTANCE_HOST_PAYLOAD_FILE) before running the acceptance test" >&2; exit 1)
	@test -n "$(FOREMAN_API_TOKEN)" || { test -n "$(FOREMAN_API_USERNAME)" && test -n "$(FOREMAN_API_PASSWORD)"; } || (echo "Set FOREMAN_API_TOKEN or both FOREMAN_API_USERNAME and FOREMAN_API_PASSWORD" >&2; exit 1)
	@TARGET_HOST="$$(terraform -chdir=$(TF_DIR) output -raw public_ip)" SSH_PRIVATE_KEY_FILE="$(SSH_PRIVATE_KEY_FILE)" FOREMAN_ACCEPTANCE_HOST_PAYLOAD_FILE="$(FOREMAN_ACCEPTANCE_HOST_PAYLOAD_FILE)" RUN_FOREMAN_ACCEPTANCE=true bundle exec rspec spec/proxmox_foreman_acceptance_spec.rb
