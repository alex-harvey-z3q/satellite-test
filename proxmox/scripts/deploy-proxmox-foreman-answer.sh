#!/usr/bin/env bash

# Deploy the Proxmox answer adapter to the Foreman host.

set -euo pipefail

foreman_host="${FOREMAN_FQDN:-REPLACE_WITH_FOREMAN_FQDN}"
handler_path="/usr/local/libexec/proxmox-foreman-answer.py"
handler_endpoint="/proxmox-answer"
foreman_vhost_config="/etc/httpd/conf.d/05-foreman.conf"
handler_socket="/run/proxmox-foreman-answer/answer.sock"
service_name="proxmox-foreman-answer"
dry_run=true
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
handler_source="$script_dir"/../files/usr/local/libexec/proxmox-foreman-answer.py
service_source="$script_dir"/../files/etc/systemd/system/proxmox-foreman-answer.service

usage() {
  cat <<'EOF'
Usage: deploy-proxmox-foreman-answer.sh [--apply]

Deploys the Proxmox JSON POST to Foreman MAC-addressed answer adapter on the Foreman host.
The default is a dry run; --apply uses interactive remote sudo.

Options:
  -a, --apply  Install, validate, and activate the adapter on the Foreman host.
  -h, --help   Show this help.
EOF
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

get_opts() {
  local opt OPTARG OPTIND

  while getopts ':ah-:' opt; do
    case "$opt" in
      a) dry_run=false ;;
      h) usage; exit 0 ;;
      -) case "$OPTARG" in
           apply) dry_run=false ;;
           help) usage; exit 0 ;;
           *) die "unknown option: --$OPTARG" ;;
         esac
         ;;
      *) usage >&2; exit 2 ;;
    esac
  done
}

validate() {
  command -v ssh >/dev/null 2>&1 || die "ssh not found"
  command -v scp >/dev/null 2>&1 || die "scp not found"

  [[ -f "$handler_source" ]] || die "answer handler source not found: $handler_source"
  [[ -f "$service_source" ]] || die "answer service source not found: $service_source"
}

write_remote_files() {
  local temporary_dir remote_dir

  temporary_dir="$(mktemp -d)"
  remote_dir="/tmp/proxmox-foreman-answer.$$"

  cat > "$temporary_dir/apply.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail

remote_dir="\$1"
backup_dir="\$(sudo mktemp -d /var/tmp/proxmox-foreman-answer.XXXXXXXX)"
handler_path="$handler_path"
foreman_vhost_config="$foreman_vhost_config"
handler_endpoint="$handler_endpoint"
handler_socket="$handler_socket"
service_name="$service_name"
service_was_enabled=false
service_was_active=false

if sudo systemctl is-enabled --quiet "\$service_name"; then
  service_was_enabled=true
fi

if sudo systemctl is-active --quiet "\$service_name"; then
  service_was_active=true
fi

backup_file() {
  local file="\$1"
  local name

  name="\$(basename "\$file")"
  if sudo test -e "\$file"; then
    sudo cp -a "\$file" "\$backup_dir/\$name"
  else
    sudo touch "\$backup_dir/.missing.\$name"
  fi
}

restore_file() {
  local file="\$1"
  local name

  name="\$(basename "\$file")"
  if sudo test -e "\$backup_dir/.missing.\$name"; then
    sudo rm -f "\$file"
  else
    sudo cp -a "\$backup_dir/\$name" "\$file"
  fi
}

restore_service_state() {
  if [[ "\$service_was_enabled" == true ]]; then
    sudo systemctl enable "\$service_name"
  else
    sudo systemctl disable "\$service_name" || true
  fi

  if [[ "\$service_was_active" == true ]]; then
    sudo systemctl restart "\$service_name"
  else
    sudo systemctl stop "\$service_name" || true
  fi
}

rollback() {
  local exit_code="\$?"

  if [[ "\$exit_code" -ne 0 ]]; then
    restore_file "\$handler_path"
    restore_file "/etc/systemd/system/\$service_name.service"
    restore_file "\$foreman_vhost_config"
    sudo systemctl daemon-reload
    restore_service_state
    sudo systemctl restart httpd
    echo "ERROR: restored pre-apply files from \$backup_dir" >&2
  else
    echo "Backup retained at \$backup_dir"
  fi
  rm -rf "\$remote_dir"
}
trap rollback EXIT

sudo test -f "\$foreman_vhost_config" || { echo "ERROR: expected Foreman Apache configuration is absent: \$foreman_vhost_config" >&2; exit 1; }
backup_file "\$handler_path"
backup_file "/etc/systemd/system/\$service_name.service"
backup_file "\$foreman_vhost_config"

sudo install -o root -g root -m 0755 "\$remote_dir/proxmox-foreman-answer.py" "\$handler_path"
sudo install -o root -g root -m 0644 "\$remote_dir/proxmox-foreman-answer.service" "/etc/systemd/system/\$service_name.service"

proxy_line="  ProxyPass \$handler_endpoint unix:\$handler_socket|http://localhost/"
if ! sudo grep -Fqx "\$proxy_line" "\$foreman_vhost_config"; then
  temporary_vhost="\$(mktemp)"
  sudo awk -v line="\$proxy_line" '
    !inserted && /^[[:space:]]*ProxyPass \/ unix:/ { print line; inserted = 1 }
    { print }
    END { if (!inserted) exit 1 }
  ' "\$foreman_vhost_config" > "\$temporary_vhost"
  sudo install -o root -g root -m 0644 "\$temporary_vhost" "\$foreman_vhost_config"
  rm -f "\$temporary_vhost"
fi

sudo httpd -t
sudo systemctl daemon-reload
sudo systemctl enable --now "\$service_name"
sudo systemctl restart httpd

status="\$(curl --silent --show-error --output /dev/null --request POST --header 'Content-Type: application/json' --data '{\"network_interfaces\":[]}' --write-out '%{http_code}' "http://127.0.0.1\$handler_endpoint")"
[[ "\$status" == 400 ]] || { echo "ERROR: expected HTTP 400 from answer handler, got \$status" >&2; exit 1; }
EOF

  # shellcheck disable=SC2029
  if ! ssh "$foreman_host" "mkdir -p '$remote_dir'"; then
    rm -rf "$temporary_dir"
    return 1
  fi
  if ! scp "$handler_source" "$service_source" "$temporary_dir/apply.sh" "$foreman_host:$remote_dir/"; then
    rm -rf "$temporary_dir"
    return 1
  fi
  if ! ssh -t "$foreman_host" "bash '$remote_dir/apply.sh' '$remote_dir'"; then
    rm -rf "$temporary_dir"
    return 1
  fi
  rm -rf "$temporary_dir"
}

print_dry_run() {
  cat <<EOF
DRY RUN: no Foreman-host files, services, or Apache configuration will change.

Planned Foreman-host changes:
  $handler_path
  /etc/systemd/system/$service_name.service
  $foreman_vhost_config -> add ProxyPass $handler_endpoint before Foreman's catch-all proxy

The apply path validates Apache, enables and starts $service_name, restarts
httpd, and verifies that an identity-free POST returns the expected HTTP 400.
EOF
}

main() {
  get_opts "$@"
  validate

  if [[ "$dry_run" == true ]]; then
    print_dry_run
    return
  fi

  write_remote_files
}

if [[ "$0" == "${BASH_SOURCE[0]}" ]]; then
  main "$@"
fi
