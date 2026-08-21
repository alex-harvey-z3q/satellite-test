# Proxmox Foreman proof of concept

This directory contains the Foreman template sources and standalone answer
adapter used by this POC.

The base Satellite installation is `make satellite-installer`.
`make satellite-customise` adds the POC-specific Apache route;
`make custom` adds the answer adapter; `make hammer` creates the Foreman
records; and `make deploy-answer-files` deploys the two custom template bodies
through Hammer. Terraform owns the AWS provisioning subnet and network access;
Satellite Installer owns DHCP, TFTP, the Smart Proxy, and Apache.

The answer adapter listens on a local Unix socket and POSTs host MAC lookups to
Foreman's local unattended-provision endpoint. Satellite Installer applies the
POC-managed Apache route for `/proxmox-answer` through custom Hiera; project
automation does not modify Satellite's generated Apache vhost.
