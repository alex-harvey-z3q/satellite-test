# Red Hat Satellite on EC2 — proof of concept

This proof of concept uses Terraform to create a RHEL 9 EC2 instance and an encrypted EBS volume for Satellite content, then uses Ansible to install Red Hat Satellite. Run the workflow through the included Makefile only.

## What this creates

- An `r6i.2xlarge` RHEL 9 EC2 instance (8 vCPU, 64 GiB memory).
- A 100 GiB encrypted gp3 root disk and a separate encrypted 500 GiB gp3 disk mounted at `/var/lib/pulp`.
- A security group restricted to the CIDRs in `terraform/terraform.tfvars`.
- An IAM role for AWS Systems Manager and the instance profile that uses it.

Red Hat documents RHEL 9 x86_64, at least 4 CPU cores, 20 GiB RAM, 4 GiB swap, a fresh FQDN host, and separate Pulp storage as Satellite prerequisites. See the [Satellite installation planning guide](https://docs.redhat.com/en/documentation/red_hat_satellite/6.18/html/installing_satellite_server_in_a_connected_network_environment/planning-satellite-server-installation_satellite).

## Before you start

You need Terraform >= 1.6, Ansible Core >= 2.15, the AWS CLI, Ruby with Bundler, a Red Hat subscription or active RHEL trial that includes Satellite access, and the private key for the EC2 key pair named in `terraform/terraform.tfvars`.

`terraform/terraform.tfvars` is a local, Git-ignored infrastructure input file. Review it before applying: it selects the AWS account region, VPC/subnet, RHEL AMI, EC2 key pair, and the CIDR allowed to connect on SSH and HTTPS. It must never contain credentials or passwords.

Authenticate the AWS CLI in the shell that will run `make`. In this environment, run `select_site` and choose `personal` first. Confirm the selected account with:

```sh
aws sts get-caller-identity
```

## Complete workflow

1. Check the local toolchain and Terraform configuration:

   ```sh
   make preflight
   ```

2. Review the exact AWS resources that would be created. This does not create anything:

   ```sh
   make plan
   ```

3. Create the EC2 host and EBS volume. Terraform will show the final plan and ask for confirmation:

   ```sh
   make apply
   ```

4. Supply the two Red Hat credentials in the current shell. `read -s` prevents the password from being echoed; do not put either value in `terraform.tfvars`, `main.yml`, a command line, or Git.

   ```sh
   read -r "RHSM_USERNAME?Red Hat login: "
   read -rs "RHSM_PASSWORD?Red Hat password: "
   echo
   export RHSM_USERNAME RHSM_PASSWORD
   ```

5. Install Satellite. `SSH_PRIVATE_KEY_FILE` must be the absolute path of the private key matching the `key_name` configured in `terraform/terraform.tfvars`. The `install` target creates the non-secret Ansible settings file when needed, installs its required collection, registers the host with Red Hat Subscription Management, mounts the Pulp disk, installs the DHCP and iPXE prerequisites before Satellite protects package changes, and runs `satellite-installer` with the Foreman Proxy DHCP and TFTP features configured for the dedicated provisioning interface.

   ```sh
   make install SSH_PRIVATE_KEY_FILE=/absolute/path/to/private-key.pem
   ```

   The install can take tens of minutes. It writes `/var/log/satellite-installer-poc.log` on the EC2 host. `satellite-installer` is safe to run again to reconcile its configuration.

6. Immediately clear the Red Hat secrets from the current shell:

   ```sh
   unset RHSM_USERNAME RHSM_PASSWORD
   ```

7. Show the instance address, Satellite FQDN, and other outputs:

   ```sh
   make output
   ```

   To connect over SSH for troubleshooting:

   ```sh
   make ssh SSH_PRIVATE_KEY_FILE=/absolute/path/to/private-key.pem
   ```

8. Destroy the POC when finished. Terraform asks for confirmation. This terminates the EC2 instance and deletes its Pulp EBS volume:

   ```sh
   make destroy
   ```

## Network and DNS

The configured security group opens SSH and Satellite HTTPS only to `ssh_cidrs` and `admin_cidrs` in `terraform/terraform.tfvars`. Before using Capsules, managed clients, provisioning, DHCP/DNS/TFTP, or remote execution, add the relevant ports from Red Hat’s port matrix.

If the laptop's public IP changes, update both access CIDRs and apply the security-group change in one interactive command:

```sh
make update-my-ip
```

For a short-lived POC, omitting `satellite_fqdn` and `hosted_zone_id` uses the EC2 internal FQDN. For a durable deployment, set both values to create a Route 53 forward record and arrange matching reverse DNS externally. Satellite requires forward and reverse DNS resolution.

## Testing the Proxmox answer adapter

After `make install`, the following is the complete Proxmox deployment workflow. Terraform creates a dedicated private provisioning subnet in the Satellite VPC. Its AWS address range is real and Foreman is configured to use it, which makes the server-side Foreman, DHCP, TFTP, iPXE, template, and answer-adapter configuration meaningful. AWS still owns DHCP for EC2 instances, so it cannot PXE-boot an EC2 test client from this server.

For this disposable POC, Satellite is installed with the documented local API credential `admin` / `Welcome1`. It is deliberately predictable so the deployment automation can run unattended; never use it outside this POC. Set the DHCP shared secret in the current shell only:

```sh
export FOREMAN_USER='admin'
export FOREMAN_PASSWORD='Welcome1'
# Generate this once; retain it in a password manager for future DHCP changes.
export PVE_DHCP_OMAPI_SECRET="$(openssl rand -base64 32 | tr -d '\n')"
```

`PVE_DHCP_OMAPI_SECRET` is a locally generated shared secret for ISC DHCP and Foreman's Smart Proxy; it is not supplied by Red Hat or AWS. Do not commit it or place it in `terraform.tfvars`.

Configure the iPXE assets from Terraform's Satellite FQDN, then run:

```sh
make proxmox-configure-fqdn
make proxmox-deploy SSH_PRIVATE_KEY_FILE=/absolute/path/to/private-key.pem
unset FOREMAN_PASSWORD PVE_DHCP_OMAPI_SECRET
```

`proxmox-configure-fqdn` is idempotent and only replaces the two `REPLACE_WITH_FOREMAN_FQDN` placeholders. `proxmox-deploy` and `proxmox-test-bootstrap` run it automatically. `proxmox-deploy` then runs the supporting Foreman prerequisites and all three supplied Bash deployers in this order: DHCP/TFTP/iPXE (including assigning the local Smart Proxy as the DHCP proxy for the Terraform subnet), Foreman templates, and the answer adapter. It finishes by re-running the idempotent prerequisites to associate the deployed provision template with the test host group. The DHCP script automatically receives Terraform's `provisioning_subnet_cidr`; do not set it yourself. `make install` persists SELinux disabled for this POC because the adapter’s Apache Unix-socket proxy requires it.

Then run the safe HTTP contract suite. It makes only invalid or deliberately unregistered requests and does not change Foreman data:

```sh
make test-contract SSH_PRIVATE_KEY_FILE=/absolute/path/to/private-key.pem
```

It verifies the deployed DHCP, Smart Proxy, iPXE, Apache, answer-adapter, systemd, Foreman subnet-proxy, host-group template-combination, and exact template-body state. It also verifies the adapter rejects incorrect methods, content types, JSON, MAC addresses, and oversized requests with the documented HTTP status codes, and that an unregistered valid MAC receives HTTP 404.

The end-to-end acceptance suite creates one disposable Foreman host, requests its answer file through Apache and the adapter, validates the returned TOML, then deletes that host. The host is named `codex-proxmox-acceptance-*`; the test refuses to delete a differently named host. It is opt-in because it needs a real host group and valid Foreman API credentials.

1. `make proxmox-test-bootstrap` is the no-DHCP alternative. It creates the same Foreman prerequisites using Terraform's dedicated provisioning subnet, deploys the adapter, and updates the templates, but does not run the DHCP/TFTP/iPXE script.

   ```sh
   make proxmox-test-bootstrap SSH_PRIVATE_KEY_FILE=/absolute/path/to/private-key.pem
   ```

   It enables end-to-end testing of the answer-file path and Bash template deployment without changing the Satellite host's DHCP service.

2. The acceptance suite uses the same `FOREMAN_USER` and `FOREMAN_PASSWORD` set above. Its API endpoint defaults to `https://` plus the Terraform public IP. TLS verification is deliberately disabled by default for this self-signed POC certificate; set `FOREMAN_API_VERIFY_TLS=true` when using a trusted certificate.

   ```sh
   export FOREMAN_ACCEPTANCE_EXPECTED_TOML_PATTERN='mailto\\s*=\\s*"operations@example\\.com"'
   ```

   To use a payload outside the default local path, export `FOREMAN_ACCEPTANCE_HOST_PAYLOAD_FILE` with its absolute path.

3. Run the acceptance suite and clear credentials afterwards:

   ```sh
   make test-acceptance SSH_PRIVATE_KEY_FILE=/absolute/path/to/private-key.pem
   unset FOREMAN_USER FOREMAN_PASSWORD
   ```

`spec/fixtures/foreman-acceptance-host.json` is Git-ignored. Do not commit it or put API credentials in it. If a test run is interrupted after creating a host, manually delete the generated `codex-proxmox-acceptance-*` host in Satellite.

## Cost and cleanup

The current Sydney defaults are approximately US$0.84/hour while running, excluding data transfer, snapshots, and tax. Stopping the instance does not stop EBS charges; use `make destroy` when the POC is no longer needed. Do not create snapshots unless you intend to retain and pay for them.
