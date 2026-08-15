#!/usr/bin/env bash

set -euo pipefail

: "${SSH_PRIVATE_KEY_FILE:?Set SSH_PRIVATE_KEY_FILE to the EC2 key PEM path.}"
: "${RHSM_USERNAME:?Set RHSM_USERNAME to your Red Hat login.}"
: "${RHSM_PASSWORD:?Set RHSM_PASSWORD to your Red Hat password.}"

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tf_dir="$root_dir/terraform"
ansible_dir="$root_dir/ansible"

host="$(terraform -chdir="$tf_dir" output -raw public_ip)"
fqdn="$(terraform -chdir="$tf_dir" output -raw satellite_fqdn)"
pulp_volume_id="$(terraform -chdir="$tf_dir" output -raw pulp_volume_id)"

if [[ -z "$host" ]]; then
  echo "No public IP was output. Use a reachable private address or run Ansible through SSM." >&2
  exit 1
fi

if [[ ! -f "$ansible_dir/group_vars/all/main.yml" ]]; then
  echo "Copy ansible/group_vars/all/main.yml.example to main.yml and populate it before running." >&2
  exit 1
fi

mkdir -p "$ansible_dir/.ansible" "$ansible_dir/collections"

ANSIBLE_LOCAL_TEMP="$ansible_dir/.ansible" \
ansible-galaxy collection install -p "$ansible_dir/collections" -r "$ansible_dir/requirements.yml"

ANSIBLE_CONFIG="$ansible_dir/ansible.cfg" \
ANSIBLE_COLLECTIONS_PATH="$ansible_dir/collections" \
ANSIBLE_LOCAL_TEMP="$ansible_dir/.ansible" \
ansible-playbook -i "$host," "$ansible_dir/site.yml" \
  --user ec2-user \
  --private-key "$SSH_PRIVATE_KEY_FILE" \
  -e "satellite_fqdn=$fqdn" \
  -e "pulp_volume_id=$pulp_volume_id"
