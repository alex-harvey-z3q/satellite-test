# Proxmox Foreman proof of concept

This directory contains the Foreman template sources and standalone answer
adapter used by this POC.

The supported deployment path is `make proxmox-deploy`. Terraform owns the AWS
provisioning subnet and network access; Satellite Installer owns DHCP, TFTP,
the Smart Proxy, and Apache; the prerequisite Ansible playbook owns the
Foreman records and the two custom template bodies through Hammer.

The answer adapter listens on a local Unix socket and POSTs host MAC lookups to
Foreman's local unattended-provision endpoint. Satellite Installer applies the
POC-managed Apache route for `/proxmox-answer` through custom Hiera; project
automation does not modify Satellite's generated Apache vhost.
