require "digest"
require "shellwords"

require "spec_helper"

PROVISIONING_SUBNET_CIDR = ENV.fetch("PROVISIONING_SUBNET_CIDR").freeze
PROVISIONING_SUBNET_NAME = ENV.fetch("PROVISIONING_SUBNET_NAME").freeze
SATELLITE_FQDN = ENV.fetch("SATELLITE_FQDN").freeze

def source_sha256(path)
  Digest::SHA256.file(File.expand_path("../#{path}", __dir__)).hexdigest
end

def remote_sha256(path)
  command("sudo sha256sum #{path.shellescape} | awk '{print $1}'")
end

RSpec.describe "the deployed Proxmox Foreman integration" do
  it "installs the exact answer-adapter handler and systemd unit" do
    expect(remote_sha256("/usr/local/libexec/proxmox-foreman-answer.py").stdout).to eq(
      "#{source_sha256('proxmox/files/usr/local/libexec/proxmox-foreman-answer.py')}\n"
    )
    expect(remote_sha256("/etc/systemd/system/proxmox-foreman-answer.service").stdout).to eq(
      "#{source_sha256('proxmox/files/etc/systemd/system/proxmox-foreman-answer.service')}\n"
    )
  end

  it "installs the exact iPXE bootstrap asset and EFI symlink" do
    expect(remote_sha256("/var/lib/tftpboot/autoexec.ipxe").stdout).to eq(
      "#{source_sha256('proxmox/assets/ipxe/autoexec.ipxe')}\n"
    )
    expect(command("sudo test -L /var/lib/tftpboot/ipxe-x64.efi && sudo test \"$(readlink /var/lib/tftpboot/ipxe-x64.efi)\" = ipxe.efi && sudo test -f /var/lib/tftpboot/ipxe.efi").exit_status).to eq(0)
  end

  it "enables the ISC DHCP Smart Proxy configuration without exposing its secret" do
    expect(command("sudo grep -Fx ':enabled: true' /etc/foreman-proxy/settings.d/dhcp.yml").exit_status).to eq(0)
    expect(command("sudo grep -Fx ':use_provider: dhcp_isc' /etc/foreman-proxy/settings.d/dhcp.yml").exit_status).to eq(0)
    expect(command("sudo grep -Fx ':server: 127.0.0.1' /etc/foreman-proxy/settings.d/dhcp.yml").exit_status).to eq(0)
    expect(command("sudo grep -Fx ':subnets:' /etc/foreman-proxy/settings.d/dhcp.yml").exit_status).to eq(0)
    expect(command("sudo grep -Fx '  - #{PROVISIONING_SUBNET_CIDR}' /etc/foreman-proxy/settings.d/dhcp.yml").exit_status).to eq(0)
    expect(command("sudo grep -Fx ':key_name: foreman-proxy-omapi' /etc/foreman-proxy/settings.d/dhcp_isc.yml").exit_status).to eq(0)
    expect(command("sudo grep -Fx ':key_algorithm: hmac-md5' /etc/foreman-proxy/settings.d/dhcp_isc.yml").exit_status).to eq(0)
    expect(command("sudo grep -Fx ':omapi_port: 7911' /etc/foreman-proxy/settings.d/dhcp_isc.yml").exit_status).to eq(0)
    expect(command("sudo grep -Eq '^:key_secret: .+' /etc/foreman-proxy/settings.d/dhcp_isc.yml").exit_status).to eq(0)
    expect(command("sudo python3 -c \"from pathlib import Path; settings = dict(line[1:].split(': ', 1) for line in Path('/etc/foreman-proxy/settings.d/dhcp_isc.yml').read_text().splitlines() if line.startswith(':key_')); include = next(line.split(chr(34))[1] for line in Path('/etc/dhcp/dhcpd.foreman-ipxe.conf').read_text().splitlines() if line.strip().startswith('secret ')); assert settings['key_secret'] == include\"").exit_status).to eq(0)
  end

  it "protects the DHCP credentials and configuration with the deployed ownership and modes" do
    expect(command("sudo stat -c '%U:%G %a' /etc/foreman-proxy/settings.d/dhcp.yml").stdout).to eq("root:foreman-proxy 640\n")
    expect(command("sudo stat -c '%U:%G %a' /etc/foreman-proxy/settings.d/dhcp_isc.yml").stdout).to eq("root:foreman-proxy 640\n")
    expect(command("sudo stat -c '%U:%G %a' /etc/dhcp/dhcpd.foreman-ipxe.conf").stdout).to eq("root:foreman-proxy 640\n")
    expect(command("sudo stat -c '%U:%G %a' /etc/dhcp/dhcpd.conf").stdout).to eq("root:foreman-proxy 640\n")
  end

  it "installs and validates the DHCP include and listener" do
    expect(command("sudo grep -Fx 'include \"/etc/dhcp/dhcpd.foreman-ipxe.conf\";' /etc/dhcp/dhcpd.conf").exit_status).to eq(0)
    expect(command("sudo grep -Fx 'omapi-port 7911;' /etc/dhcp/dhcpd.foreman-ipxe.conf").exit_status).to eq(0)
    expect(command("sudo grep -Fx 'key \"foreman-proxy-omapi\" {' /etc/dhcp/dhcpd.foreman-ipxe.conf").exit_status).to eq(0)
    expect(command("sudo grep -Fx '  algorithm hmac-md5;' /etc/dhcp/dhcpd.foreman-ipxe.conf").exit_status).to eq(0)
    expect(command("sudo grep -Eq '^  secret \".+\";$' /etc/dhcp/dhcpd.foreman-ipxe.conf").exit_status).to eq(0)
    expect(command("sudo dhcpd -t -cf /etc/dhcp/dhcpd.conf").exit_status).to eq(0)
  end

  it "runs the DHCP and answer-adapter services" do
    expect(service("dhcpd")).to be_enabled
    expect(service("dhcpd")).to be_running
    expect(service("foreman-proxy")).to be_enabled
    expect(service("foreman-proxy")).to be_running
    expect(service("proxmox-foreman-answer")).to be_enabled
    expect(service("proxmox-foreman-answer")).to be_running
    expect(command("sudo test -S /run/proxmox-foreman-answer/answer.sock").exit_status).to eq(0)
    expect(service("httpd")).to be_enabled
    expect(service("httpd")).to be_running
  end

  it "routes the answer endpoint to the adapter before Foreman's catch-all proxy" do
    expect(command("sudo grep -Fx '  ProxyPass /proxmox-answer unix:/run/proxmox-foreman-answer/answer.sock|http://localhost/' /etc/httpd/conf.d/05-foreman.conf").exit_status).to eq(0)
    expect(command("python3 -c \"lines = open('/etc/httpd/conf.d/05-foreman.conf').read().splitlines(); assert next(i for i, line in enumerate(lines) if 'ProxyPass /proxmox-answer ' in line) < next(i for i, line in enumerate(lines) if 'ProxyPass / unix:///run/foreman.sock' in line)\"").exit_status).to eq(0)
    expect(command("sudo httpd -t").exit_status).to eq(0)
  end

  it "assigns the local Smart Proxy as DHCP proxy for the Terraform provisioning subnet" do
    result = command("sudo hammer subnet info --name #{PROVISIONING_SUBNET_NAME.shellescape}")

    expect(result.exit_status).to eq(0)
    expect(result.stdout).to include("#{PROVISIONING_SUBNET_CIDR.split('/').first}")
    expect(result.stdout).to include("#{SATELLITE_FQDN}")
  end

  it "deploys the exact Proxmox Foreman template bodies" do
    expect(command("sudo hammer template dump --name 'Proxmox Autoinstall Answer File' | sha256sum | awk '{print $1}'").stdout).to eq(
      "#{source_sha256('proxmox/erb/answer.toml.erb')}\n"
    )
    expect(command("sudo hammer template dump --name 'Proxmox VE PXEiPXE' | sha256sum | awk '{print $1}'").stdout).to eq(
      "#{source_sha256('proxmox/erb/ipxe.erb')}\n"
    )
  end

  it "associates the Proxmox provision template with the acceptance host group" do
    result = command("sudo hammer template info --name 'Proxmox Autoinstall Answer File'")

    expect(result.exit_status).to eq(0)
    expect(result.stdout).to include("proxmox-ve 9")
    expect(result.stdout).to include("Proxmox AWS Acceptance Test")
  end

  it "cleans up the remote staging directories after successful deployment" do
    expect(command("test -z \"$(sudo find /tmp -maxdepth 1 -type d \\( -name 'proxmox-foreman-ipxe.*' -o -name 'proxmox-foreman-answer.*' \\) -print -quit)\"").exit_status).to eq(0)
  end

  it "retains recovery backups from the DHCP and adapter deployers" do
    expect(command("sudo find /var/tmp -maxdepth 1 -type d -name 'proxmox-foreman-ipxe.*' -print -quit | grep -q .").exit_status).to eq(0)
    expect(command("sudo find /var/tmp -maxdepth 1 -type d -name 'proxmox-foreman-answer.*' -print -quit | grep -q .").exit_status).to eq(0)
  end
end
