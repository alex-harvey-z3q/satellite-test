# Supported Proxmox configuration

`satellite_installer.yml` applies the POC-specific Apache route through Satellite
Installer custom Hiera. `answer_service.yml` installs the standalone
answer adapter. `templates.yml` updates the two custom Foreman template bodies
through local Hammer. `hammer.yml` manages the required Foreman records
through Hammer.

Satellite Installer owns DHCP, TFTP, Smart Proxy settings, and Apache. The POC
declares a small Puppet class through `custom-hiera.yaml` so the installer also
manages the `/proxmox-answer` route.

After `make install`, from the repository root run the technology-layer targets
in order:

```sh
export SSH_PRIVATE_KEY_FILE=/absolute/path/to/private-key.pem

make hammer
make satellite-installer
make answer-service
make templates
```
