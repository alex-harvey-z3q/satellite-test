#!/usr/bin/env bash

# Configure shared iPXE bootstrap infrastructure on the Foreman host. Foreman owns only
# per-host DHCP reservations through OMAPI; this script does not add MAC rules.
#
# PROOF OF CONCEPT ONLY.
#
# A production solution would implement this configuration through
# Puppet or Ansible.

set -euo pipefail

foreman_host="${FOREMAN_FQDN:-REPLACE_WITH_FOREMAN_FQDN}"
provisioning_subnet_cidr="${PROVISIONING_SUBNET_CIDR:-REPLACE_WITH_PROVISIONING_SUBNET_CIDR}"
subnet_names=()
all_subnets=false
tftp_root="/var/lib/tftpboot"
dhcp_config="/etc/dhcp/dhcpd.conf"
dhcp_include="/etc/dhcp/dhcpd.foreman-ipxe.conf"
proxy_dhcp_settings="/etc/foreman-proxy/settings.d/dhcp.yml"
proxy_isc_settings="/etc/foreman-proxy/settings.d/dhcp_isc.yml"
omapi_key_name="foreman-proxy-omapi"
omapi_key_algorithm="hmac-md5"
omapi_port="7911"
dry_run=true
configure_foreman=false
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
autoexec_script="$script_dir"/../assets/ipxe/autoexec.ipxe

usage() {
  cat <<'EOF'
Usage: configure-foreman-ipxe-dhcp.sh [--apply | --configure-foreman SCOPE]

Installs shared iPXE bootstrap infrastructure on the Foreman host. Foreman then manages DHCP
reservations for Build hosts whose PXE loader is iPXE Chain UEFI.

Options:
  -a, --apply             Make Foreman-host changes. Default is dry run.
  -f, --configure-foreman Assign the Foreman host as the DHCP proxy through the Foreman API.
                          Requires a SCOPE, FOREMAN_USER, and FOREMAN_PASSWORD.
      --subnet NAME       Assign the Foreman host as DHCP proxy to this subnet. Repeatable.
      --all-subnets       Assign the Foreman host as DHCP proxy to every Foreman subnet.
  -h                       Show this help.

Environment required with --apply:
  PVE_DHCP_OMAPI_SECRET    ISC DHCP OMAPI shared secret.
EOF
}

get_opts() {
  local opt OPTARG OPTIND subnet_name

  while getopts ':afh-:' opt; do
    case "$opt" in
      a) dry_run=false ;;
      f) configure_foreman=true ;;
      h) usage; exit 0 ;;
      -)
        case "$OPTARG" in
          apply) dry_run=false ;;
          configure-foreman) configure_foreman=true ;;
          subnet)
            subnet_name="${!OPTIND:-}"
            [[ -n "$subnet_name" ]] || die "--subnet requires a name"
            subnet_names+=("$subnet_name")
            OPTIND=$((OPTIND + 1))
            ;;
          subnet=*)
            subnet_name="${OPTARG#subnet=}"
            [[ -n "$subnet_name" ]] || die "--subnet requires a name"
            subnet_names+=("$subnet_name")
            ;;
          all-subnets) all_subnets=true ;;
          help) usage; exit 0 ;;
          *) die "unknown option: --$OPTARG" ;;
        esac
        ;;
      *) usage >&2; exit 2 ;;
    esac
  done
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

validate() {
  if [[ "$configure_foreman" == true ]]; then
    [[ "$dry_run" == true ]] || die "--apply cannot be combined with --configure-foreman"

    command -v curl    >/dev/null 2>&1 || die "curl not found"
    command -v python3 >/dev/null 2>&1 || die "python3 not found"

    [[ -n "${FOREMAN_USER:-}" && -n "${FOREMAN_PASSWORD:-}" ]] || die "FOREMAN_USER and FOREMAN_PASSWORD are required with --configure-foreman"

    [[ "$all_subnets" == true  || "${#subnet_names[@]}" -gt 0 ]] || die "--subnet NAME or --all-subnets is required with Foreman configuration"
    [[ "$all_subnets" == false || "${#subnet_names[@]}" -eq 0 ]] || die "--all-subnets cannot be combined with --subnet"

    return
  fi

  command -v ssh >/dev/null 2>&1 || die "ssh not found"
  command -v scp >/dev/null 2>&1 || die "scp not found"

  [[ -f "$autoexec_script" ]] || die "iPXE autoexec script not found: $autoexec_script"

  if [[ "$dry_run" == false ]]; then
    [[ -n "${PVE_DHCP_OMAPI_SECRET:-}" ]] || die "PVE_DHCP_OMAPI_SECRET is required with --apply"
    [[ "$PVE_DHCP_OMAPI_SECRET" != *'"'* && "$PVE_DHCP_OMAPI_SECRET" != *$'\n'* ]] || die "OMAPI secret must not contain a quote or newline"
  fi
}

write_remote_files() {
  local temporary_dir remote_dir

  temporary_dir="$(mktemp -d)"
  remote_dir="/tmp/proxmox-foreman-ipxe.$$"

  cat > "$temporary_dir/dhcp.yml" <<EOF
---
:enabled: true
:use_provider: dhcp_isc
:server: 127.0.0.1
:subnets:
  - $provisioning_subnet_cidr
EOF
  cat > "$temporary_dir/dhcp_isc.yml" <<EOF
---
:enabled: true
:key_name: $omapi_key_name
:key_secret: $PVE_DHCP_OMAPI_SECRET
:key_algorithm: $omapi_key_algorithm
:omapi_port: $omapi_port
EOF
  cat > "$temporary_dir/dhcpd.foreman-ipxe.conf" <<EOF
# Managed by configure-foreman-ipxe-dhcp.sh. Foreman Smart Proxy uses this
# OMAPI key to create and remove DHCP reservations for managed Build hosts.
key "$omapi_key_name" {
  algorithm $omapi_key_algorithm;
  secret "$PVE_DHCP_OMAPI_SECRET";
}
omapi-port $omapi_port;
EOF
  cat > "$temporary_dir/apply.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail

remote_dir="\$1"
backup_dir="\$(sudo mktemp -d /var/tmp/proxmox-foreman-ipxe.XXXXXXXX)"
dhcpd_was_enabled=false
dhcpd_was_active=false
foreman_proxy_was_enabled=false
foreman_proxy_was_active=false

if sudo systemctl is-enabled --quiet dhcpd; then
  dhcpd_was_enabled=true
fi

if sudo systemctl is-active --quiet dhcpd; then
  dhcpd_was_active=true
fi

if sudo systemctl is-enabled --quiet foreman-proxy; then
  foreman_proxy_was_enabled=true
fi

if sudo systemctl is-active --quiet foreman-proxy; then
  foreman_proxy_was_active=true
fi

backup_file() {
  local file="\$1"
  local name

  name="\$(basename "\$file")"
  if sudo test -e "\$file" || sudo test -L "\$file"; then
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
  local service="\$1"
  local was_enabled="\$2"
  local was_active="\$3"

  if [[ "\$was_enabled" == true ]]; then
    sudo systemctl enable "\$service"
  else
    sudo systemctl disable "\$service"
  fi

  if [[ "\$was_active" == true ]]; then
    sudo systemctl restart "\$service"
  else
    sudo systemctl stop "\$service"
  fi
}

rollback() {
  local exit_code="\$?"

  if [[ "\$exit_code" -ne 0 ]]; then
    restore_file "$tftp_root/autoexec.ipxe"
    restore_file "$tftp_root/ipxe-x64.efi"
    restore_file "$proxy_dhcp_settings"
    restore_file "$proxy_isc_settings"
    restore_file "$dhcp_include"
    restore_file "$dhcp_config"
    sudo dhcpd -t -cf "$dhcp_config"
    restore_service_state dhcpd "\$dhcpd_was_enabled" "\$dhcpd_was_active"
    restore_service_state foreman-proxy "\$foreman_proxy_was_enabled" "\$foreman_proxy_was_active"
    echo "ERROR: restored pre-apply files from \$backup_dir" >&2
  else
    echo "Backup retained at \$backup_dir"
  fi
  rm -rf "\$remote_dir"
}

trap rollback EXIT

backup_file "$tftp_root/autoexec.ipxe"
backup_file "$tftp_root/ipxe-x64.efi"
backup_file "$proxy_dhcp_settings"
backup_file "$proxy_isc_settings"
backup_file "$dhcp_include"
backup_file "$dhcp_config"

sudo grep -Eq '^:enabled: (false|true)$' "$proxy_dhcp_settings"
sudo sed -i 's/^:enabled: false\$/:enabled: true/' "$proxy_dhcp_settings"

if ! sudo grep -Fqx ':subnets:' "$proxy_dhcp_settings"; then
  printf '%s\n' ':subnets:' '  - $provisioning_subnet_cidr' | sudo tee -a "$proxy_dhcp_settings" >/dev/null
fi

sudo chmod 0640 "$proxy_dhcp_settings"

if sudo grep -Eq '^:key_(name|secret|algorithm):' "$proxy_isc_settings"; then
  echo "ERROR: $proxy_isc_settings already has an active OMAPI key" >&2
  exit 1
fi

printf '%s\n' ':key_name: $omapi_key_name' ':key_secret: $PVE_DHCP_OMAPI_SECRET' ':key_algorithm: $omapi_key_algorithm' | sudo tee -a "$proxy_isc_settings" >/dev/null
sudo chmod 0640 "$proxy_isc_settings"

sudo install -m 0644 "\$remote_dir/autoexec.ipxe" "$tftp_root/autoexec.ipxe"
sudo install -o root -g foreman-proxy -m 0640 "\$remote_dir/dhcpd.foreman-ipxe.conf" "$dhcp_include"
sudo test -f "$tftp_root/ipxe.efi"
sudo ln -sfn ipxe.efi "$tftp_root/ipxe-x64.efi"

if ! sudo grep -Fqx 'include "$dhcp_include";' "$dhcp_config"; then
  echo 'include "$dhcp_include";' | sudo tee -a "$dhcp_config" >/dev/null
fi

sudo chgrp foreman-proxy "$dhcp_config"
sudo chmod 0640 "$dhcp_config"
sudo dhcpd -t -cf "$dhcp_config"
sudo systemctl restart dhcpd foreman-proxy
EOF

  # shellcheck disable=SC2029
  if ! ssh "$foreman_host" "mkdir -p '$remote_dir'"; then
    rm -rf "$temporary_dir"
    return 1
  fi
  if ! scp "$autoexec_script" "$temporary_dir/dhcpd.foreman-ipxe.conf" "$temporary_dir/apply.sh" "$foreman_host:$remote_dir/"; then
    rm -rf "$temporary_dir"
    return 1
  fi
  if ! ssh -t "$foreman_host" "bash '$remote_dir/apply.sh' '$remote_dir'"; then
    rm -rf "$temporary_dir"
    return 1
  fi
  rm -rf "$temporary_dir"
}

foreman_get() {
  local path="$1"
  shift

  curl --fail --silent --show-error --get --user "$FOREMAN_USER:$FOREMAN_PASSWORD" "https://$foreman_host$path" "$@"
}

list_subnet_ids() {
  local subnet_name

  if [[ "$all_subnets" == true ]]; then
    foreman_get /api/subnets --data-urlencode 'per_page=9999' |
      python3 -c 'import json, sys; [print(subnet["id"]) for subnet in json.load(sys.stdin).get("results", [])]'
    return
  fi

  for subnet_name in "${subnet_names[@]}"; do
    foreman_get /api/subnets --data-urlencode "search=name = $subnet_name" --data-urlencode 'per_page=100' |
      python3 -c '
import json
import sys

results = json.load(sys.stdin).get("results", [])
if len(results) != 1:
    raise SystemExit("Expected exactly one subnet named {!r}, found {}".format(sys.argv[1], len(results)))
print(results[0]["id"])
' "$subnet_name"
  done
}

configure_foreman_subnets() {
  local proxy_id subnet_id payload
  local -a subnet_ids

  proxy_id="$(foreman_get /api/smart_proxies --data-urlencode "search=name = $foreman_host" --data-urlencode 'per_page=100' | python3 -c 'import json,sys; results=json.load(sys.stdin).get("results", []); assert len(results) == 1, "Expected exactly one Foreman Smart Proxy"; print(results[0]["id"])')"
  mapfile -t subnet_ids < <(list_subnet_ids)
  [[ "${#subnet_ids[@]}" -gt 0 ]] || die "no Foreman subnets matched the requested scope"

  for subnet_id in "${subnet_ids[@]}"; do
    payload="{\"subnet\":{\"dhcp_id\":$proxy_id}}"
    curl --fail --silent --show-error --user "$FOREMAN_USER:$FOREMAN_PASSWORD" -X PUT -H 'Content-Type: application/json' -d "$payload" "https://$foreman_host/api/subnets/$subnet_id" >/dev/null
  done
}

print_dry_run() {
  cat <<EOF
DRY RUN: no Foreman-host files, services, DHCP reservations, or Foreman records will change.

Shared Foreman-host assets:
  $tftp_root/autoexec.ipxe -> chains /unattended/iPXE?bootstrap=1
  $tftp_root/ipxe-x64.efi -> symlink to the existing ipxe.efi binary

Managed Foreman-host configuration:
  $dhcp_include -> OMAPI listener and Foreman Smart Proxy key
  $proxy_dhcp_settings -> enable DHCP provider dhcp_isc for $provisioning_subnet_cidr
  $proxy_isc_settings -> ISC OMAPI credentials
  $dhcp_config -> include $dhcp_include

Foreman behavior after applying:
  Unknown hosts retain the existing GRUB discovery DHCP default.
  Known Build hosts using iPXE Chain UEFI receive ipxe-x64.efi through their
  Foreman-managed DHCP reservation, then chain to Foreman's MAC dispatcher.
EOF
}

main() {
  get_opts "$@"
  validate

  if [[ "$configure_foreman" == true ]]; then
    configure_foreman_subnets
    return
  fi

  if [[ "$dry_run" == true ]]; then
    print_dry_run
    return
  fi

  write_remote_files
}

if [[ "$0" == "${BASH_SOURCE[0]}" ]]; then
  main "$@"
fi
