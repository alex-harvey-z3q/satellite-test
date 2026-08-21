require "spec_helper"

ADAPTER_URL = ENV.fetch("PROXMOX_ANSWER_URL", "http://127.0.0.1/proxmox-answer").freeze
UNKNOWN_MAC = ENV.fetch("PROXMOX_CONTRACT_UNKNOWN_MAC", "02:00:00:00:00:01").freeze

def adapter_status(arguments)
  command(
    "curl --silent --output /dev/null --write-out '%{http_code}' #{arguments} #{ADAPTER_URL}"
  ).stdout
end

describe "the Proxmox Foreman answer-adapter HTTP contract" do
  it "rejects GET requests" do
    expect(adapter_status("--request GET")).to eq "405"
  end

  it "requires a JSON content type" do
    expect(adapter_status("--request POST --data '{}'" )).to eq "415"
  end

  it "rejects malformed JSON" do
    expect(adapter_status("--request POST --header 'Content-Type: application/json' --data 'not-json'" )).to eq "400"
  end

  it "rejects a request with no usable MAC address" do
    expect(adapter_status("--request POST --header 'Content-Type: application/json' --data '{\"network_interfaces\":[{\"mac\":\"not-a-mac\"}]}'" )).to eq "400"
  end

  it "rejects oversized request bodies" do
    expect(
      adapter_status(
        "--request POST --header 'Content-Type: application/json' --data-binary @<(head -c 131073 /dev/zero)"
      )
    ).to eq "413"
  end

  it "returns not found for a valid, unregistered MAC address" do
    expect(
      adapter_status(
        "--request POST --header 'Content-Type: application/json' --data '{\"network_interfaces\":[{\"mac\":\"#{UNKNOWN_MAC}\"}]}'"
      )
    ).to eq "404"
  end
end
