SHELL := /bin/bash

TF_DIR := terraform
ANSIBLE_DIR := ansible
INSTALLER := scripts/install.sh
FOREMAN_ACCEPTANCE_HOST_PAYLOAD_FILE ?= $(CURDIR)/spec/fixtures/foreman-acceptance-host.json

TERRAFORM := terraform -chdir=$(TF_DIR)
tf_output = $(TERRAFORM) output -raw $(1)
ANSIBLE_PLAYBOOK := ANSIBLE_CONFIG=$(CURDIR)/$(ANSIBLE_DIR)/ansible.cfg ANSIBLE_LOCAL_TEMP=$(CURDIR)/$(ANSIBLE_DIR)/.ansible ansible-playbook
ANSIBLE_REMOTE_ARGS = --user ec2-user --private-key "$(SSH_PRIVATE_KEY_FILE)" --ssh-common-args="-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$(CURDIR)/$(ANSIBLE_DIR)/.ansible/known_hosts"
PROXMOX_SSH := ssh -i "$(SSH_PRIVATE_KEY_FILE)" -o StrictHostKeyChecking=accept-new
PROXMOX_SCP := scp -i "$(SSH_PRIVATE_KEY_FILE)" -o StrictHostKeyChecking=accept-new

define require_ssh_private_key
@test -n "$(SSH_PRIVATE_KEY_FILE)" || (echo "Set SSH_PRIVATE_KEY_FILE to the private key for the EC2 key pair" >&2; exit 1)
endef

define require_foreman_credentials
@test -n "$${FOREMAN_USER:-}" || (echo "Export FOREMAN_USER for a Satellite API user" >&2; exit 1)
@test -n "$${FOREMAN_PASSWORD:-}" || (echo "Export FOREMAN_PASSWORD for that user's password" >&2; exit 1)
endef

define require_proxmox_dhcp_inputs
$(require_ssh_private_key)
$(require_foreman_credentials)
@test -n "$${PVE_DHCP_OMAPI_SECRET:-}" || (echo "Export PVE_DHCP_OMAPI_SECRET" >&2; exit 1)
endef

define proxmox_ssh_functions
ssh() { command $(PROXMOX_SSH) -o User=ec2-user "$$@"; }; \
scp() { command $(PROXMOX_SCP) -o User=ec2-user "$$@"; }; \
export -f ssh scp;
endef

.DEFAULT_GOAL := help

.PHONY: help init fmt validate preflight configure plan apply update-my-ip install output ssh destroy proxmox-configure-fqdn proxmox-answer proxmox-prerequisites proxmox-templates proxmox-test-bootstrap proxmox-dhcp proxmox-deploy proxmox-legacy-deploy proxmox-ansible-deploy test-setup acceptance-fixture test-contract test-acceptance

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
	$(ANSIBLE_PLAYBOOK) --syntax-check -i 'localhost,' $(ANSIBLE_DIR)/proxmox_prerequisites.yml
	$(ANSIBLE_PLAYBOOK) --syntax-check -i 'localhost,' $(ANSIBLE_DIR)/proxmox/deploy.yml

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
	$(TERRAFORM) apply

update-my-ip: ## Detect the current public IPv4, update SSH/HTTPS CIDRs, then apply Terraform.
	@test -f $(TF_DIR)/terraform.tfvars || (echo "Create $(TF_DIR)/terraform.tfvars before updating access CIDRs" >&2; exit 1)
	@public_ip="$$(curl --fail --silent --show-error https://checkip.amazonaws.com | tr -d '\n')"; \
	[[ "$$public_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$$ ]] || (echo "Could not determine a public IPv4 address" >&2; exit 1); \
	ruby scripts/update-access-cidrs.rb $(TF_DIR)/terraform.tfvars "$$public_ip"; \
	echo "Updated SSH and HTTPS access CIDRs to $$public_ip/32"
	$(MAKE) apply

install: configure ## Install Satellite. Requires SSH_PRIVATE_KEY_FILE, RHSM_USERNAME, and RHSM_PASSWORD.
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

proxmox-configure-fqdn: ## Replace the iPXE FQDN placeholders using Terraform's Satellite FQDN.
	@set -e; fqdn="$$($(call tf_output,satellite_fqdn))"; \
	test -n "$$fqdn" || { echo "Terraform did not return a Satellite FQDN" >&2; exit 1; }; \
	SATELLITE_FQDN="$$fqdn" ruby -e 'fqdn = ENV.fetch("SATELLITE_FQDN"); paths = %w[proxmox/assets/ipxe/autoexec.ipxe proxmox/erb/ipxe.erb]; paths.each do |path|; content = File.read(path); if content.include?("REPLACE_WITH_FOREMAN_FQDN"); File.write(path, content.gsub("REPLACE_WITH_FOREMAN_FQDN", fqdn)); elsif !content.include?(fqdn); abort("#{path} contains neither the placeholder nor Terraform\047s Satellite FQDN; refusing to overwrite it"); end; end'

proxmox-answer: ## Deploy the Proxmox answer adapter. Requires SSH_PRIVATE_KEY_FILE.
	$(require_ssh_private_key)
	@set -e; host="$$($(call tf_output,public_ip))"; \
	$(proxmox_ssh_functions) \
	FOREMAN_FQDN="$$host" bash proxmox/scripts/deploy-proxmox-foreman-answer.sh --apply

proxmox-prerequisites: ## Create Foreman test objects using Terraform's dedicated provisioning subnet.
	$(require_ssh_private_key)
	@set -e; subnet_name="$$($(call tf_output,provisioning_subnet_name))"; \
	$(ANSIBLE_PLAYBOOK) \
		-i "$$($(call tf_output,public_ip))," \
		$(ANSIBLE_DIR)/proxmox_prerequisites.yml \
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

proxmox-templates: ## Update Proxmox Foreman templates. Requires SSH_PRIVATE_KEY_FILE, FOREMAN_USER, and FOREMAN_PASSWORD.
	$(require_ssh_private_key)
	$(require_foreman_credentials)
	@! rg -q 'REPLACE_WITH_FOREMAN_FQDN' proxmox/assets/ipxe/autoexec.ipxe proxmox/erb/ipxe.erb || (echo "Replace REPLACE_WITH_FOREMAN_FQDN in the Proxmox iPXE assets before deploying templates" >&2; exit 1)
	@host="$$($(call tf_output,public_ip))"; \
	fqdn="$$($(call tf_output,satellite_fqdn))"; \
	local_dir="$$(mktemp -d)"; \
	trap 'rm -rf "$$local_dir"' EXIT; \
	env_file="$$local_dir/foreman.env"; \
	remote_dir="/tmp/proxmox-templates-$$$$"; \
	(umask 077; printf 'FOREMAN_FQDN=%q\nFOREMAN_USER=%q\nFOREMAN_PASSWORD=%q\n' "$$fqdn" "$${FOREMAN_USER}" "$${FOREMAN_PASSWORD}" > "$$env_file"); \
	$(PROXMOX_SSH) ec2-user@"$$host" "mkdir -p '$$remote_dir'"; \
	$(PROXMOX_SCP) -r proxmox/assets proxmox/erb proxmox/scripts "$$env_file" ec2-user@"$$host":"$$remote_dir/"; \
	$(PROXMOX_SSH) -tt ec2-user@"$$host" "set -e; set -a; . '$$remote_dir/foreman.env'; set +a; rm -f '$$remote_dir/foreman.env'; bash '$$remote_dir/scripts/deploy-proxmox-foreman-templates.sh' --apply"; \
	$(PROXMOX_SSH) ec2-user@"$$host" "rm -rf '$$remote_dir'"

proxmox-test-bootstrap: ## Deploy the supported Proxmox test configuration.
	$(MAKE) proxmox-deploy SSH_PRIVATE_KEY_FILE="$(SSH_PRIVATE_KEY_FILE)"

proxmox-dhcp: ## Configure DHCP/TFTP/iPXE and assign its proxy to the provisioning subnet. Requires SSH_PRIVATE_KEY_FILE, FOREMAN_USER, FOREMAN_PASSWORD, and PVE_DHCP_OMAPI_SECRET.
	$(require_proxmox_dhcp_inputs)
	@set -e; host="$$($(call tf_output,public_ip))"; \
	fqdn="$$($(call tf_output,satellite_fqdn))"; \
	subnet_cidr="$$($(call tf_output,provisioning_subnet_cidr))"; \
	subnet_name="$$($(call tf_output,provisioning_subnet_name))"; \
	local_dir="$$(mktemp -d)"; \
	trap 'rm -rf "$$local_dir"' EXIT; \
	env_file="$$local_dir/foreman.env"; \
	remote_dir="/tmp/proxmox-foreman-dhcp-$$$$"; \
	$(proxmox_ssh_functions) \
	FOREMAN_FQDN="$$host" PROVISIONING_SUBNET_CIDR="$$subnet_cidr" PVE_DHCP_OMAPI_SECRET="$${PVE_DHCP_OMAPI_SECRET}" bash proxmox/scripts/configure-foreman-ipxe-dhcp.sh --apply; \
	(umask 077; printf 'FOREMAN_FQDN=%q\nFOREMAN_USER=%q\nFOREMAN_PASSWORD=%q\n' "$$fqdn" "$${FOREMAN_USER}" "$${FOREMAN_PASSWORD}" > "$$env_file"); \
	ssh ec2-user@"$$host" "mkdir -p '$$remote_dir'"; \
	scp proxmox/scripts/configure-foreman-ipxe-dhcp.sh "$$env_file" ec2-user@"$$host":"$$remote_dir/"; \
	ssh -tt ec2-user@"$$host" "set -e; set -a; . '$$remote_dir/foreman.env'; set +a; rm -f '$$remote_dir/foreman.env'; bash '$$remote_dir/configure-foreman-ipxe-dhcp.sh' --configure-foreman --subnet '$$subnet_name'; rm -rf '$$remote_dir'"

proxmox-legacy-deploy: ## Legacy unmanaged-file Bash deployment; retained only for comparison and not supported by Satellite Installer.
	$(MAKE) proxmox-configure-fqdn
	$(MAKE) proxmox-prerequisites SSH_PRIVATE_KEY_FILE="$(SSH_PRIVATE_KEY_FILE)"
	$(MAKE) proxmox-dhcp SSH_PRIVATE_KEY_FILE="$(SSH_PRIVATE_KEY_FILE)"
	$(MAKE) proxmox-templates SSH_PRIVATE_KEY_FILE="$(SSH_PRIVATE_KEY_FILE)"
	$(MAKE) proxmox-answer SSH_PRIVATE_KEY_FILE="$(SSH_PRIVATE_KEY_FILE)"
	$(MAKE) proxmox-prerequisites SSH_PRIVATE_KEY_FILE="$(SSH_PRIVATE_KEY_FILE)"

proxmox-deploy: ## Deploy the supported Proxmox configuration through Satellite Installer and Hammer.
	$(require_ssh_private_key)
	$(MAKE) proxmox-prerequisites SSH_PRIVATE_KEY_FILE="$(SSH_PRIVATE_KEY_FILE)"
	@$(ANSIBLE_PLAYBOOK) \
		-i "$$($(call tf_output,public_ip))," \
		$(ANSIBLE_REMOTE_ARGS) \
		-e "proxmox_foreman_fqdn=$$($(call tf_output,satellite_fqdn))" \
		$(ANSIBLE_DIR)/proxmox/deploy.yml

proxmox-ansible-deploy: ## Alias for the supported Ansible Proxmox deployment.
	$(MAKE) proxmox-deploy SSH_PRIVATE_KEY_FILE="$(SSH_PRIVATE_KEY_FILE)"

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
