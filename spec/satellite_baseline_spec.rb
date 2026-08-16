require "spec_helper"

describe package("satellite") do
  it { is_expected.to be_installed }
end

describe service("httpd") do
  it { is_expected.to be_enabled }
  it { is_expected.to be_running }
end

describe service("foreman") do
  it { is_expected.to be_enabled }
  it { is_expected.to be_running }
end

describe port(443) do
  it { is_expected.to be_listening }
end

describe file("/var/lib/pulp") do
  it { is_expected.to be_directory }
end

describe command("findmnt --noheadings --output FSTYPE /var/lib/pulp") do
  its(:stdout) { is_expected.to eq "xfs\n" }
end
