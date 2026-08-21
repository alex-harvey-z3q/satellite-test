# Supported Proxmox configuration

`deploy.yml` installs only the standalone answer adapter and updates the two
custom Foreman template bodies through local Hammer. The parent
`proxmox_prerequisites.yml` manages the required Foreman records through
Hammer.

Satellite Installer owns DHCP, TFTP, Smart Proxy settings, and Apache. The POC
declares a small Puppet class through `custom-hiera.yaml` so the installer also
manages the `/proxmox-answer` route. The deprecated
`configure_foreman_ipxe_dhcp.yml` is retained as an implementation reference
only and is not imported by `deploy.yml`.

From the repository root, use the automated entry point:

```sh
make proxmox-deploy SSH_PRIVATE_KEY_FILE=/absolute/path/to/private-key.pem
```
