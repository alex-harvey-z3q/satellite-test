# Red Hat Satellite on EC2 — proof of concept

This proof of concept creates a RHEL 9 EC2 instance and a dedicated encrypted EBS volume for Satellite content, then installs Red Hat Satellite with Ansible.

It uses an existing VPC and subnet, and does not create a public network, a NAT gateway, or a Route 53 hosted zone. The selected subnet must have egress to Red Hat CDN and AWS Systems Manager. The instance role is included for Systems Manager access; the supplied runner uses SSH.

## Prerequisites

- Terraform >= 1.6, AWS CLI credentials for the target account, and Ansible Core >= 2.15.
- An existing x86_64 RHEL 9 AMI which your account is entitled to use (for example, through Red Hat Cloud Access), an existing VPC/subnet, and an EC2 key pair with its matching private key. The supplied Ansible runner connects over SSH.
- A Red Hat Satellite subscription and an activation key that entitles this host to the Satellite and RHEL repositories.

Red Hat currently documents RHEL 9 x86_64, 4 CPU cores, 20 GiB RAM, 4 GiB swap, a fresh host with a FQDN, and a separately mounted `/var/lib/pulp` volume. The default instance (`r6i.2xlarge`) and 500 GiB gp3 content volume deliberately exceed the minimum for a small POC. See Red Hat's [installation planning guide](https://docs.redhat.com/en/documentation/red_hat_satellite/6.18/html/installing_satellite_server_in_a_connected_network_environment/planning-satellite-server-installation_satellite).

## Deploy

1. Configure AWS credentials and copy the input example:

   ```sh
   cp terraform/terraform.tfvars.example terraform/terraform.tfvars
   # edit terraform/terraform.tfvars; do not commit it
   terraform -chdir=terraform init
   terraform -chdir=terraform plan
   terraform -chdir=terraform apply
   ```

2. Copy and edit the non-secret Ansible variables:

   ```sh
   cp ansible/group_vars/all/main.yml.example ansible/group_vars/all/main.yml
   ```

3. Run the installer. The EC2 key must match `key_name` in Terraform. Supply the Red Hat credentials only through environment variables; do not put them in a shell history, Terraform file, or Ansible variable file.

   ```sh
   read -r "RHSM_USERNAME?Red Hat login: "
   read -rs "RHSM_PASSWORD?Red Hat password: "
   export RHSM_USERNAME RHSM_PASSWORD
   SSH_PRIVATE_KEY_FILE=/absolute/path/to/key.pem ./scripts/install.sh
   unset RHSM_PASSWORD
   ```

The play writes an installation log to `/var/log/satellite-installer-poc.log`. A successful run prints the initial admin password; retrieve it from that file on the host. Re-running is safe after the initial installation: it skips `satellite-installer` when `/etc/foreman/settings.yaml` exists.

## Network and DNS

The security group allows HTTPS from `admin_cidrs` and optional SSH from `ssh_cidrs`. Add the required inbound ports before adding Capsules, managed clients, DHCP/DNS/TFTP, or remote-execution features. Red Hat's complete port matrix is authoritative.

When `satellite_fqdn` and `hosted_zone_id` are set, Terraform creates a forward DNS record. Otherwise, the short-lived POC uses the EC2 internal FQDN. It does not attempt to fabricate reverse DNS, custom certificates, content manifests, Capsules, or client provisioning.

## Teardown

Destroying the stack terminates the instance and deletes the data volume because it is a POC:

```sh
terraform -chdir=terraform destroy
```

Take a backup or snapshot before destroying anything you want to retain.
