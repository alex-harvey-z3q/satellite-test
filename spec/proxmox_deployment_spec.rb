require "digest"
require "shellwords"

require "spec_helper"

PROVISIONING_SUBNET_CIDR = ENV.fetch("PROVISIONING_SUBNET_CIDR").freeze
PROVISIONING_SUBNET_NAME = ENV.fetch("PROVISIONING_SUBNET_NAME").freeze
SATELLITE_FQDN = ENV.fetch("SATELLITE_FQDN").freeze

def source_sha256(path)
  Digest::SHA256.file(File.expand_path("../#{path}", __dir__)).hexdigest
end

def rendered_template_sha256(path)
  Digest::SHA256.hexdigest(
    File.read(File.expand_path("../#{path}", __dir__)).gsub("REPLACE_WITH_FOREMAN_FQDN", SATELLITE_FQDN)
  )
end

def remote_sha256(path)
  command("sudo sha256sum #{path.shellescape} | awk '{print $1}'")
end

RSpec.describe "the supported Proxmox Foreman integration" do
  it "installs the exact standalone answer-adapter handler and systemd unit" do
    expect(remote_sha256("/usr/local/libexec/proxmox-foreman-answer.py").stdout).to eq(
      "#{source_sha256('proxmox/files/usr/local/libexec/proxmox-foreman-answer.py')}\n"
    )
    expect(remote_sha256("/etc/systemd/system/proxmox-foreman-answer.service").stdout).to eq(
      "#{source_sha256('proxmox/files/etc/systemd/system/proxmox-foreman-answer.service')}\n"
    )
  end

  it "runs the adapter behind the installer-managed Apache route" do
    expect(service("proxmox-foreman-answer")).to be_enabled
    expect(service("proxmox-foreman-answer")).to be_running
    expect(command("sudo test -S /run/proxmox-foreman-answer/answer.sock").exit_status).to eq(0)
    expect(command("sudo grep -Fx '  - proxmox_answer' /etc/foreman-installer/custom-hiera.yaml").exit_status).to eq(0)
    expect(command("sudo grep -Fx 'ProxyPass /proxmox-answer unix:/run/proxmox-foreman-answer/answer.sock|http://localhost/' /etc/httpd/conf.d/04-proxmox-answer.conf").exit_status).to eq(0)
    expect(command("sudo httpd -t").exit_status).to eq(0)
  end

  it "installs the exact custom Hiera Puppet module for the Apache route" do
    expect(remote_sha256("/usr/share/foreman-installer/modules/proxmox_answer/manifests/init.pp").stdout).to eq(
      "#{source_sha256('ansible/files/foreman-installer/modules/proxmox_answer/manifests/init.pp')}\n"
    )
    expect(remote_sha256("/etc/foreman-installer/custom-hiera.yaml").stdout).to eq(
      "#{source_sha256('ansible/files/foreman-installer/custom-hiera.yaml')}\n"
    )
  end

  it "uses the DHCP and TFTP services configured by Satellite Installer" do
    expect(service("dhcpd")).to be_enabled
    expect(service("dhcpd")).to be_running
    expect(service("foreman-proxy")).to be_enabled
    expect(service("foreman-proxy")).to be_running
    expect(command("sudo dhcpd -t -cf /etc/dhcp/dhcpd.conf").exit_status).to eq(0)
    expect(command("sudo test ! -e /etc/dhcp/dhcpd.foreman-ipxe.conf").exit_status).to eq(0)
  end

  it "does not install repository-managed TFTP bootstrap files" do
    expect(command("sudo test ! -e /var/lib/tftpboot/autoexec.ipxe").exit_status).to eq(0)
    expect(command("sudo test ! -L /var/lib/tftpboot/ipxe-x64.efi").exit_status).to eq(0)
  end

  it "assigns the installer-managed Smart Proxy as DHCP proxy for the Terraform provisioning subnet" do
    result = command("sudo hammer subnet info --name #{PROVISIONING_SUBNET_NAME.shellescape}")

    expect(result.exit_status).to eq(0)
    expect(result.stdout).to include(PROVISIONING_SUBNET_CIDR.split('/').first)
    expect(result.stdout).to include(SATELLITE_FQDN)
  end

  it "deploys the exact Proxmox Foreman template bodies" do
    expect(command("sudo hammer template dump --name 'Proxmox Autoinstall Answer File' | sha256sum | awk '{print $1}'").stdout).to eq(
      "#{source_sha256('proxmox/erb/answer.toml.erb')}\n"
    )
    expect(command("sudo hammer template dump --name 'Proxmox VE PXEiPXE' | sha256sum | awk '{print $1}'").stdout).to eq(
      "#{rendered_template_sha256('proxmox/erb/ipxe.erb')}\n"
    )
  end

  it "associates the Proxmox provisioning templates and Satellite-served iPXE loader with the acceptance host group" do
    template = command("sudo hammer template info --name 'Proxmox Autoinstall Answer File'")
    hostgroup = command("sudo hammer hostgroup info --name 'Proxmox AWS Acceptance Test'")

    expect(template.exit_status).to eq(0)
    expect(template.stdout).to include("proxmox-ve 9")
    expect(hostgroup.exit_status).to eq(0)
    expect(hostgroup.stdout).to include("iPXE Chain UEFI")
    expect(hostgroup.stdout).to include(PROVISIONING_SUBNET_NAME)
  end
end
