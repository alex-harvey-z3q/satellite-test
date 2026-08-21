# Red Hat Satellite support for Proxmox Automation

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

5. Install base Satellite. `SSH_PRIVATE_KEY_FILE` must be the absolute path of the private key matching the `key_name` configured in `terraform/terraform.tfvars`. The `satellite-installer` target creates the non-secret Ansible settings file when needed, installs its required collection, registers the host with Red Hat Subscription Management, mounts the Pulp disk, and runs `satellite-installer` with the Foreman Proxy DHCP and TFTP features configured for the dedicated provisioning interface.

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

```text
                         Dedicated provisioning subnet

  +---------------------+                                      +-----------------------------------------------+
  | Proxmox host        |                                      | Satellite EC2 host                            |
  | provisioning NIC    |                                      |                                               |
  |                     | -- DHCPDISCOVER, UDP/67 -----------> | ISC DHCP (installer-managed)                  |
  |                     | <--- lease, boot instructions ------ |   ^                                           |
  |                     |                                      |   | OMAPI: reservations and boot configuration|
  |                     | -- TFTP, UDP/69 -------------------> |   |                                           |
  |                     | <--- network boot artefacts -------- | Smart Proxy (installer-managed)               |
  |                     |                                      |   ^                                           |
  |                     | -- HTTP iPXE boot -----------------> |   | Foreman API                               |
  |                     | <--- rendered iPXE template -------- | Foreman: host, subnet, host group, templates  |
  |                     |                                      |                                               |
  | Proxmox installer   | -- POST /proxmox-answer -----------> | Apache                                        |
  |   sends NIC MACs    | <--- rendered TOML answer file ----- |   | ProxyPass (Puppet/Hiera-managed)          |
  |                     |                                      |   v                                           |
  |                     |                                      | proxmox-foreman-answer.service                |
  |                     |                                      |   | Unix socket HTTP                          |
  |                     |                                      |   v                                           |
  |                     |                                      | Foreman /unattended/provision?mac=...         |
  +---------------------+                                      +-----------------------------------------------+
```

### Code path

```text
                                developer workstation

  Makefile
     |
     +-- make install -------------------------------------------------------->
     |   scripts/install.sh --> ansible/site.yml --> satellite-installer
     |                                           --> base Satellite
     |                                               DHCP/TFTP/Smart Proxy
     |
     +-- make hammer --------------------------------------------------------+
         +-- ansible/proxmox_prerequisites.yml --> Hammer --> Foreman domain,
         |                                                subnet, host group,
         |                                              template associations
         |
     +-- make satellite-installer -------------------------------------------+
     |   ansible/proxmox/customise.yml
     |      +-- files/foreman-installer/custom-hiera.yaml
     |      +-- files/foreman-installer/modules/proxmox_answer/
     |      |     manifests/init.pp
     |      +-- satellite-installer --> POC Apache /proxmox-answer route
     |
     +-- make answer-service ------------------------------------------------+
         |
         +-- deploy_foreman_answer.yml
               +-- proxmox/files/.../proxmox-foreman-answer.py
               +-- proxmox/files/.../proxmox-foreman-answer.service
                     --> systemd --> Unix socket
     |
     +-- make templates -----------------------------------------------------+
         +-- ansible/proxmox/deploy.yml
              +-- deploy_foreman_templates.yml
                   +-- proxmox/erb/answer.toml.erb -- Hammer --> Foreman template
                   +-- proxmox/erb/ipxe.erb        -- Hammer --> Foreman template
```

`make install` configures DHCP, TFTP, and Smart Proxy through `satellite-installer`. `make satellite-installer` applies the POC-specific Apache route through the same installer and its Puppet catalog. `make answer-service` installs the standalone answer service. The Hammer targets manage only Foreman objects and templates; they do not modify DHCP or Smart Proxy configuration files directly.

After `make install`, the base Satellite configuration contains no
Proxmox-specific Apache route or answer service. Apply the POC in its
technology-layer order:

```sh
make hammer SSH_PRIVATE_KEY_FILE=/absolute/path/to/private-key.pem
make satellite-installer SSH_PRIVATE_KEY_FILE=/absolute/path/to/private-key.pem
make answer-service SSH_PRIVATE_KEY_FILE=/absolute/path/to/private-key.pem
make templates SSH_PRIVATE_KEY_FILE=/absolute/path/to/private-key.pem
```

The targets are intentionally independent. Run them in the order shown above:
the answer route should exist before the answer service is exposed, and Hammer
must create the template records before `make templates` can update
their bodies.

Terraform creates the dedicated provisioning subnet and allows DHCP, TFTP, and HTTP boot only from that subnet. Satellite Installer owns the local DHCP and TFTP services; the prerequisite playbook manages the Foreman domain, subnet-to-Smart-Proxy association, operating system, host group, and template associations through Hammer. The Proxmox template bodies are stored in Satellite itself.

The answer adapter retains the required `http://<Satellite-FQDN>/proxmox-answer` endpoint. Its Unix-socket service is routed by an Apache fragment created by a POC Puppet class declared in `custom-hiera.yaml` and applied during `make satellite-installer`. No project automation edits `dhcpd.conf`, Smart Proxy YAML, `/var/lib/tftpboot`, or Satellite’s generated `05-foreman.conf`.

The supported deployment renders the Satellite FQDN into the iPXE template in memory; it does not modify the tracked template source.

For this disposable POC, Satellite's initial local API credential is `admin` / `Welcome1`. It is deliberately predictable so the automation can run unattended; never use it outside this POC. Set the API credentials only for the acceptance test:

```sh
export FOREMAN_USER='admin'
export FOREMAN_PASSWORD='Welcome1'
```

Then run the safe HTTP contract suite. It makes only invalid or deliberately unregistered requests and does not change Foreman data:

```sh
make test-contract SSH_PRIVATE_KEY_FILE=/absolute/path/to/private-key.pem
```

It verifies the installer-managed services, standalone answer adapter, Foreman subnet/proxy association, host-group boot configuration, template associations, and exact template bodies. It also verifies the adapter rejects incorrect methods, content types, JSON, MAC addresses, and oversized requests with the documented HTTP status codes, and that an unregistered valid MAC receives HTTP 404.

The end-to-end acceptance suite creates one disposable Foreman host, requests its answer file from the standalone adapter, validates the returned TOML, then deletes that host. The host is named `codex-proxmox-acceptance-*`; the test refuses to delete a differently named host. Its API endpoint defaults to `https://` plus the Terraform public IP. Run it with:

```sh
make test-acceptance SSH_PRIVATE_KEY_FILE=/absolute/path/to/private-key.pem
unset FOREMAN_USER FOREMAN_PASSWORD
```

`spec/fixtures/foreman-acceptance-host.json` is Git-ignored. Do not commit it or put API credentials in it. If a test run is interrupted after creating a host, manually delete the generated `codex-proxmox-acceptance-*` host in Satellite.

## Cost and cleanup

The current Sydney defaults are approximately US$0.84/hour while running, excluding data transfer, snapshots, and tax. Stopping the instance does not stop EBS charges; use `make destroy` when the POC is no longer needed. Do not create snapshots unless you intend to retain and pay for them.
