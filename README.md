# Red Hat Satellite on EC2 — proof of concept

This proof of concept uses Terraform to create a RHEL 9 EC2 instance and an encrypted EBS volume for Satellite content, then uses Ansible to install Red Hat Satellite. Run the workflow through the included Makefile only.

## What this creates

- An `r6i.2xlarge` RHEL 9 EC2 instance (8 vCPU, 64 GiB memory).
- A 100 GiB encrypted gp3 root disk and a separate encrypted 500 GiB gp3 disk mounted at `/var/lib/pulp`.
- A security group restricted to the CIDRs in `terraform/terraform.tfvars`.
- An IAM role for AWS Systems Manager and the instance profile that uses it.

Red Hat documents RHEL 9 x86_64, at least 4 CPU cores, 20 GiB RAM, 4 GiB swap, a fresh FQDN host, and separate Pulp storage as Satellite prerequisites. See the [Satellite installation planning guide](https://docs.redhat.com/en/documentation/red_hat_satellite/6.18/html/installing_satellite_server_in_a_connected_network_environment/planning-satellite-server-installation_satellite).

## Before you start

You need Terraform >= 1.6, Ansible Core >= 2.15, the AWS CLI, a Red Hat subscription or active RHEL trial that includes Satellite access, and the private key for the EC2 key pair named in `terraform/terraform.tfvars`.

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

4. Supply the two Red Hat credentials only in the current shell. `read -s` prevents the password from being echoed; do not put either value in `terraform.tfvars`, `main.yml`, a command line, or Git.

   ```sh
   read -r "RHSM_USERNAME?Red Hat login: "
   read -rs "RHSM_PASSWORD?Red Hat password: "
   export RHSM_USERNAME RHSM_PASSWORD
   ```

5. Install Satellite. `SSH_PRIVATE_KEY_FILE` must be the absolute path of the private key matching the `key_name` configured in `terraform/terraform.tfvars`. The `install` target creates the non-secret Ansible settings file when needed, installs its required collection, registers the host with Red Hat Subscription Management, mounts the Pulp disk, and runs `satellite-installer`.

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

For a short-lived POC, omitting `satellite_fqdn` and `hosted_zone_id` uses the EC2 internal FQDN. For a durable deployment, set both values to create a Route 53 forward record and arrange matching reverse DNS externally. Satellite requires forward and reverse DNS resolution.

## Cost and cleanup

The current Sydney defaults are approximately US$0.84/hour while running, excluding data transfer, snapshots, and tax. Stopping the instance does not stop EBS charges; use `make destroy` when the POC is no longer needed. Do not create snapshots unless you intend to retain and pay for them.
