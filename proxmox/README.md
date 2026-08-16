# Foreman Proxmox Deployment

This directory contains the dry-run-first scripts that connect Foreman, the
Foreman Smart Proxy, ISC DHCP, TFTP iPXE, and the Proxmox unattended installer.
Set `FOREMAN_FQDN` and `PROVISIONING_SUBNET_CIDR` before applying the scripts.
Replace `REPLACE_WITH_FOREMAN_FQDN` in `assets/ipxe/autoexec.ipxe` and
`erb/ipxe.erb` before deploying iPXE templates.

## Architecture

### Control plane

```
                        Foreman host record
                  Build mode + iPXE Chain UEFI
                                  |
                                  | Host lifecycle and DHCP reservation API
                                  v
    +------------------------- Foreman host ---------------------------------------+
    |                                                                              |
    |  Foreman Smart Proxy                 OMAPI key, port 7911                    |
    |  DHCP provider: dhcp_isc  ---------------------------------+                 |
    |  server: 127.0.0.1                                         |                 |
    |  subnet: configured provisioning CIDR                       v                 |
    |                                                   +-------------------+      |
    |                                                   | ISC DHCP          |      |
    |                                                   | dhcpd.conf        |      |
    |                                                   |   includes OMAPI  |      |
    |                                                   |   reservation API |      |
    |                                                   +---------+---------+      |
    |                                                             |                |
    |  TFTP                                                       | DHCP offer/ack |
    |    ipxe-x64.efi -> ipxe.efi <-------------------------------+                |
    |    autoexec.ipxe -> /unattended/iPXE?bootstrap=1                             |
    +------------------------------------------------------------------------------+
                                  ^
                                  | DHCP/TFTP on the actual associated VLAN/relay
                                  |
                     +------------+-------------+
                     | Physical Proxmox host    |
                     | UEFI PXE provisioning NIC|
                     +------------+-------------+
                                  |
                                  | iPXE HTTP chain, host resolved by MAC
                                  v
                       Foreman iPXE template
                                  |
                                  | HTTP boot artifacts
                                  v
        http://<foreman-fqdn>/pub/proxmox/pve/
                  vmlinuz, initrd.img, generated auto-install ISO
```

### Run-time answer path

```
                     Proxmox automatic installer
                                  |
                                  | POST /proxmox-answer
                                  | { network_interfaces: [{ link, mac }, ...] }
                                  v
    +------------------------- Foreman host ------------------------------------+
    | Apache                                                                    |
    |   ProxyPass /proxmox-answer                                               |
    |     unix:/run/proxmox-foreman-answer/answer.sock                          |
    |                                  |                                        |
    |                                  v                                        |
    | proxmox-foreman-answer.service (apache user)                              |
    |   - validates and deduplicates MAC addresses                              |
    |   - queries all submitted MACs concurrently                               |
    |   - returns the first non-404 Foreman response                            |
    |                                  |                                        |
    |                                  | Unix socket HTTP                       |
    |                                  v                                        |
    | Foreman /run/foreman.sock                                                 |
    |   GET /unattended/provision?mac=<mac>                                     |
    +---------------------------------------------------------------------------+
                                  |
                                  | Rendered Provision template as TOML
                                  v
                     Proxmox installer configures host
```

### Ownership boundaries

Foreman:
* Host records, effective host/global parameters, build state, templates.
* Per-host DHCP reservations through Smart Proxy OMAPI.

Smart Proxy / ISC DHCP:
* Reservation API connection and the shared DHCP service.

Deployment scripts:
* Shared OMAPI include, Smart Proxy settings, TFTP iPXE bootstrap,
  Apache adapter mapping, service unit, and template body deployment.

Physical network:
* The provisioning NIC's switch port, VLAN, relay, and reachable DHCP scope.
* A Foreman reservation cannot redirect a host booting on another DHCP scope.

## Scripts

| Script | Purpose |
| --- | --- |
| `scripts/configure-foreman-ipxe-dhcp.sh` | Establish the shared DHCP, OMAPI, TFTP, and iPXE bootstrap path. |
| `scripts/deploy-proxmox-foreman-answer.sh` | Deploy the JSON-to-Foreman answer adapter and its Apache Unix-socket proxy. |
| `scripts/deploy-proxmox-foreman-templates.sh` | Update the existing Foreman Provision and iPXE template bodies. |

All scripts show the planned actions by default. Use `--apply` only after
reviewing the dry run. No script creates arbitrary DHCP MAC rules: Foreman
creates, updates, and removes reservations for managed Build hosts through the
Smart Proxy's OMAPI connection.

## Bootstrap Path

`scripts/configure-foreman-ipxe-dhcp.sh` configures shared Foreman-host assets:

- ISC DHCP OMAPI include at `/etc/dhcp/dhcpd.foreman-ipxe.conf`.
- Smart Proxy DHCP/ISC configuration for the configured provisioning CIDR.
- TFTP `ipxe-x64.efi` symlink and `autoexec.ipxe` bootstrap script.
- The `dhcpd.conf` include and service validation/restart.

Known Foreman hosts in Build mode using the `iPXE Chain UEFI` loader receive a
Foreman-managed reservation with the iPXE binary as their boot file. Unknown
hosts keep the existing GRUB Discovery behavior.

The host must physically PXE boot through the subnet and DHCP relay associated
with the Foreman host. A Foreman reservation does not override the physical VLAN, relay, or
DHCP scope reached by the provisioning NIC.

To associate the Foreman host with selected Foreman subnets, use the explicit API mode:

```bash
FOREMAN_USER='your-user' FOREMAN_PASSWORD='REDACTED' \
  bash scripts/configure-foreman-ipxe-dhcp.sh --configure-foreman --subnet <provisioning-subnet-name>
```

`--configure-foreman` is an API write even though it is separate from the
server-side `--apply` mode. Scope it with one or more `--subnet` arguments; use
`--all-subnets` only when that broader relationship is intended.

## Answer Path

The prepared Proxmox ISO POSTs its runtime network-interface inventory to
`/proxmox-answer`. Apache forwards the request over a Unix socket to
`proxmox-foreman-answer.service`. The adapter queries Foreman's unattended
Provision endpoint for the submitted MAC addresses and returns the rendered
TOML answer file.

The adapter source and systemd unit are maintained outside this directory:

```text
../files/usr/local/libexec/proxmox-foreman-answer.py
../files/etc/systemd/system/proxmox-foreman-answer.service
```

The adapter queries all supplied non-loopback MAC addresses concurrently and
returns the first non-404 Foreman response. This accommodates installer payloads
that include inactive NICs before the active provisioning interface.

## Template Deployment

`scripts/deploy-proxmox-foreman-templates.sh` updates only the template body of these
existing exact name-and-kind pairs:

| Name | Kind | Source |
| --- | --- | --- |
| `Proxmox Autoinstall Answer File` | `Provision` | `../erb/answer.toml.erb` |
| `Proxmox VE PXEiPXE` | `iPXE` | `../erb/ipxe.erb` |

It preserves template associations, operating-system assignments, and taxonomy.
It does not create missing templates.

The answer template uses the effective `remote_execution_ssh_keys` host/global
parameter, when nonempty, to render Proxmox `root-ssh-keys`; the installer writes
those public keys to root's `authorized_keys` file.

## Apply Preconditions

| Operation | Required environment |
| --- | --- |
| DHCP/iPXE `--apply` | `PVE_DHCP_OMAPI_SECRET` |
| Foreman subnet association | `FOREMAN_USER`, `FOREMAN_PASSWORD` |
| Template `--apply` | `FOREMAN_USER`, `FOREMAN_PASSWORD` |
| Answer adapter `--apply` | Interactive SSH and remote `sudo` access to the Foreman host |

The server-side apply scripts stage files over SSH, retain a backup directory,
validate configuration before activation, and restore prior files/service state
when their apply sequence fails.
