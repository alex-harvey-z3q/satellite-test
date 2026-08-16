#!/usr/bin/env bash

# Update the existing Proxmox provisioning templates through Foreman's API.

set -euo pipefail

foreman_host="${FOREMAN_FQDN:-REPLACE_WITH_FOREMAN_FQDN}"
dry_run=true
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
answer_template="$script_dir"/../erb/answer.toml.erb
ipxe_template="$script_dir"/../erb/ipxe.erb

usage() {
  cat <<'EOF'
Usage: deploy-proxmox-foreman-templates.sh [--apply]

Updates the existing Proxmox Foreman provisioning templates. The default is a
dry run; --apply requires FOREMAN_USER and FOREMAN_PASSWORD.

Options:
  -a, --apply  Update templates through the Foreman API.
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
  [[ -f "$answer_template" ]] || die "answer template not found: $answer_template"
  [[ -f "$ipxe_template" ]] || die "iPXE template not found: $ipxe_template"

  if [[ "$dry_run" == false ]]; then
    command -v curl >/dev/null 2>&1 || die "curl not found"
    command -v python3 >/dev/null 2>&1 || die "python3 not found"
    [[ -n "${FOREMAN_USER:-}" && -n "${FOREMAN_PASSWORD:-}" ]] || die "FOREMAN_USER and FOREMAN_PASSWORD are required with --apply"
  fi
}

foreman_get() {
  local path="$1"
  shift

  curl --fail --silent --show-error --get --user "$FOREMAN_USER:$FOREMAN_PASSWORD" "https://$foreman_host$path" "$@"
}

find_template_id() {
  local template_name="$1"
  local template_kind="$2"

  foreman_get /api/provisioning_templates \
  --data-urlencode 'per_page=9999' |
    python3 -c '
import json
import sys

name, kind = sys.argv[1:]
templates = json.load(sys.stdin).get("results", [])
same_name = [template for template in templates if template.get("name") == name]
matches = [template for template in same_name if template.get("template_kind_name") == kind]
if len(matches) != 1:
  found_kinds = sorted({str(template.get("template_kind_name")) for template in same_name})
  raise SystemExit("Expected exactly one visible template named {!r} with kind {!r}, found {}. Same-name kinds: {}".format(name, kind, len(matches), ", ".join(found_kinds) if found_kinds else "none"))
print(matches[0]["id"])
' "$template_name" "$template_kind"
}

template_needs_update() {
  local template_id="$1"
  local template_file="$2"

  foreman_get "/api/provisioning_templates/$template_id" |
    python3 -c '
import json
import pathlib
import sys

current = json.load(sys.stdin).get("template")
desired = pathlib.Path(sys.argv[1]).read_text()
raise SystemExit(0 if current == desired else 1)
' "$template_file"
}

update_template() {
  local template_id="$1"
  local template_file="$2"

  python3 -c '
import json
import pathlib
import sys

print(json.dumps({"provisioning_template": {"template": pathlib.Path(sys.argv[1]).read_text()}}))
' "$template_file" |
    curl --fail --silent --show-error --user "$FOREMAN_USER:$FOREMAN_PASSWORD" \
      --request PUT \
      --header 'Content-Type: application/json' \
      --data-binary @- \
      "https://$foreman_host/api/provisioning_templates/$template_id" >/dev/null
}

deploy_template() {
  local template_name="$1"
  local template_kind="$2"
  local template_file="$3"
  local template_id

  template_id="$(find_template_id "$template_name" "$template_kind")"

  if template_needs_update "$template_id" "$template_file"; then
    echo "UNCHANGED: $template_name ($template_kind, ID $template_id)"
  else
    update_template "$template_id" "$template_file"
    echo "UPDATED: $template_name ($template_kind, ID $template_id)"
  fi
}

print_dry_run() {
  cat <<EOF
DRY RUN: no Foreman templates will change.

Planned API updates on https://$foreman_host:
  $answer_template -> Proxmox Autoinstall Answer File (Provision)
  $ipxe_template -> Proxmox VE PXEiPXE (iPXE)

The apply path updates only the template body of existing exact name-and-kind
matches. It preserves operating-system, taxonomy, and template associations.
EOF
}

main() {
  get_opts "$@"
  validate

  if [[ "$dry_run" == true ]]; then
    print_dry_run
    return
  fi

  deploy_template 'Proxmox Autoinstall Answer File' provision "$answer_template"
  deploy_template 'Proxmox VE PXEiPXE' iPXE "$ipxe_template"
}

if [[ "$0" == "${BASH_SOURCE[0]}" ]]; then
  main "$@"
fi
