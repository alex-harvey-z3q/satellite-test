# Supported Proxmox configuration

`customise.yml` applies the POC-specific Apache route through Satellite
Installer custom Hiera. `deploy_foreman_answer.yml` installs the standalone
answer adapter. `deploy.yml` updates the two custom Foreman template bodies
through local Hammer. The parent `proxmox_prerequisites.yml` manages the
required Foreman records through Hammer.

Satellite Installer owns DHCP, TFTP, Smart Proxy settings, and Apache. The POC
declares a small Puppet class through `custom-hiera.yaml` so the installer also
manages the `/proxmox-answer` route.

From the repository root, run the technology-layer targets in order:

```sh
make satellite-installer SSH_PRIVATE_KEY_FILE=/absolute/path/to/private-key.pem
make answer-service SSH_PRIVATE_KEY_FILE=/absolute/path/to/private-key.pem
make hammer SSH_PRIVATE_KEY_FILE=/absolute/path/to/private-key.pem
make templates SSH_PRIVATE_KEY_FILE=/absolute/path/to/private-key.pem
```
