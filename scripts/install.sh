#!/usr/bin/env bash

set -euo pipefail

: "${SSH_PRIVATE_KEY_FILE:?Set SSH_PRIVATE_KEY_FILE to the EC2 key PEM path.}"
: "${RHSM_USERNAME:?Set RHSM_USERNAME to your Red Hat login.}"
: "${RHSM_PASSWORD:?Set RHSM_PASSWORD to your Red Hat password.}"

# This is a disposable proof of concept. Override only when intentionally testing
# a different credential; do not use this default outside the POC.
satellite_admin_password="${SATELLITE_ADMIN_PASSWORD:-Welcome1}"

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tf_dir="$root_dir/terraform"
ansible_dir="$root_dir/ansible"

host="$(terraform -chdir="$tf_dir" output -raw public_ip)"
fqdn="$(terraform -chdir="$tf_dir" output -raw satellite_fqdn)"
pulp_volume_id="$(terraform -chdir="$tf_dir" output -raw pulp_volume_id)"
provisioning_subnet_cidr="$(terraform -chdir="$tf_dir" output -raw provisioning_subnet_cidr)"
provisioning_subnet_network="$(terraform -chdir="$tf_dir" output -raw provisioning_subnet_network)"
provisioning_subnet_mask="$(terraform -chdir="$tf_dir" output -raw provisioning_subnet_mask)"
provisioning_subnet_gateway="$(terraform -chdir="$tf_dir" output -raw provisioning_subnet_gateway)"
provisioning_interface_ip="$(terraform -chdir="$tf_dir" output -raw provisioning_interface_private_ip)"
provisioning_dhcp_range_start="$(terraform -chdir="$tf_dir" output -raw provisioning_dhcp_range_start)"
provisioning_dhcp_range_end="$(terraform -chdir="$tf_dir" output -raw provisioning_dhcp_range_end)"

if [[ -z "$host" ]]; then
  echo "No public IP was output. Use a reachable private address or run Ansible through SSM." >&2
  exit 1
fi

if [[ ! -f "$ansible_dir/group_vars/all/main.yml" ]]; then
  echo "Copy ansible/group_vars/all/main.yml.example to main.yml and populate it before running." >&2
  exit 1
fi

mkdir -p "$ansible_dir/.ansible" "$ansible_dir/collections"
known_hosts_file="$ansible_dir/.ansible/known_hosts"
inventory_file="$ansible_dir/.ansible/inventory.ini"

printf '[satellite]\n%s\n' "$host" > "$inventory_file"

ANSIBLE_CONFIG="$ansible_dir/ansible.cfg" \
ANSIBLE_COLLECTIONS_PATH="$ansible_dir/collections" \
ANSIBLE_LOCAL_TEMP="$ansible_dir/.ansible" \
ansible-galaxy collection install --force -p "$ansible_dir/collections" -r "$ansible_dir/requirements.yml"

ANSIBLE_CONFIG="$ansible_dir/ansible.cfg" \
ANSIBLE_COLLECTIONS_PATH="$ansible_dir/collections" \
ANSIBLE_LOCAL_TEMP="$ansible_dir/.ansible" \
ansible-playbook -i "$inventory_file" "$ansible_dir/site.yml" \
  --user ec2-user \
  --private-key "$SSH_PRIVATE_KEY_FILE" \
  --ssh-common-args="-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$known_hosts_file" \
  -e "satellite_fqdn=$fqdn" \
  -e "satellite_initial_admin_password=$satellite_admin_password" \
  -e "pulp_volume_id=$pulp_volume_id" \
  -e "satellite_provisioning_subnet_cidr=$provisioning_subnet_cidr" \
  -e "satellite_provisioning_subnet_network=$provisioning_subnet_network" \
  -e "satellite_provisioning_subnet_mask=$provisioning_subnet_mask" \
  -e "satellite_provisioning_subnet_gateway=$provisioning_subnet_gateway" \
  -e "satellite_provisioning_interface_ip=$provisioning_interface_ip" \
  -e "satellite_provisioning_dhcp_range_start=$provisioning_dhcp_range_start" \
  -e "satellite_provisioning_dhcp_range_end=$provisioning_dhcp_range_end"
