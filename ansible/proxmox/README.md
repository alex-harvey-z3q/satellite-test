# Proxmox Foreman Ansible implementation

These playbooks are an Ansible implementation of the three scripts in
`proxmox/scripts/`. They do not call or modify those scripts.

Run them from the repository root after Satellite is installed. Provide secrets
only as environment variables or through an external Ansible secret provider;
never commit them in inventory or variable files.

```sh
ANSIBLE_CONFIG=ansible/ansible.cfg ansible-playbook \
  -i "$(terraform -chdir=terraform output -raw public_ip)," \
  -u ec2-user --private-key /absolute/path/to/private-key.pem \
  -e proxmox_foreman_fqdn="$(terraform -chdir=terraform output -raw satellite_fqdn)" \
  -e proxmox_provisioning_subnet_cidr="$(terraform -chdir=terraform output -raw provisioning_subnet_cidr)" \
  -e proxmox_dhcp_omapi_secret="$PVE_DHCP_OMAPI_SECRET" \
  ansible/proxmox/configure_foreman_ipxe_dhcp.yml
```

Use `deploy_foreman_templates.yml` and `deploy_foreman_answer.yml` with
`proxmox_foreman_api_user` and `proxmox_foreman_api_password`, for example:

```sh
-e "proxmox_foreman_api_user=$FOREMAN_USER" \\
-e "proxmox_foreman_api_password=$FOREMAN_PASSWORD"
```

Keep those shell variables out of version control. The DHCP playbook configures
the Foreman subnet proxy only when `proxmox_configure_foreman_dhcp=true`.
