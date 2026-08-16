require "spec_helper"

describe file("/usr/local/libexec/proxmox-foreman-answer.py") do
  it { is_expected.to be_file }
  it { is_expected.to be_executable }
end

describe service("proxmox-foreman-answer") do
  it { is_expected.to be_enabled }
  it { is_expected.to be_running }
end

describe command("test -S /run/proxmox-foreman-answer/answer.sock") do
  its(:exit_status) { is_expected.to eq 0 }
end

describe command("curl --silent --output /dev/null --write-out '%{http_code}' --request POST --header 'Content-Type: application/json' --data '{\"network_interfaces\":[]}' http://127.0.0.1/proxmox-answer") do
  its(:stdout) { is_expected.to eq "400" }
end
