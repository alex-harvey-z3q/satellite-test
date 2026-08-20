require "json"
require "base64"
require "net/http"
require "net/ssh"
require "openssl"
require "securerandom"
require "toml-rb"
require "uri"

require "spec_helper"

RSpec.describe "the Proxmox Foreman answer-adapter acceptance flow" do
  before(:all) do
    skip "Set RUN_FOREMAN_ACCEPTANCE=true to run the Foreman API acceptance test" unless ENV["RUN_FOREMAN_ACCEPTANCE"] == "true"

    @payload_file = ENV.fetch("FOREMAN_ACCEPTANCE_HOST_PAYLOAD_FILE")
    @api_base_url = ENV.fetch("FOREMAN_API_URL", "https://#{ENV.fetch('TARGET_HOST')}").sub(%r{/$}, "")
    @expected_toml_pattern = Regexp.new(ENV.fetch("FOREMAN_ACCEPTANCE_EXPECTED_TOML_PATTERN", "mailto\\s*=\\s*\\\"operations@example\\.com\\\""))
    @hostname = "codex-proxmox-acceptance-#{SecureRandom.hex(4)}"
    @mac = [0x02, *SecureRandom.random_bytes(5).bytes].map { |byte| format("%02x", byte) }.join(":")
    @host_id = nil

    create_test_host
  end

  after(:all) do
    delete_test_host if @host_id
  end

  it "returns a valid TOML answer file for the newly-created Foreman host" do
    response = answer_adapter_request(JSON.generate(network_interfaces: [{ mac: @mac }]))

    headers, body = response.split(/\r?\n\r?\n/, 2)
    expect(headers).to match(%r{^HTTP/.* 200}i), "Adapter response body: #{body}"
    expect(headers).to match(/^Content-Type:\s*application\/toml/i)
    expect(body).to match(@expected_toml_pattern)
    expect { TomlRB.parse(body) }.not_to raise_error
  end

  private

  def create_test_host
    payload = File.read(@payload_file)
                  .gsub("__TEST_HOSTNAME__", @hostname)
                  .gsub("__TEST_MAC__", @mac)
    raise "FOREMAN_ACCEPTANCE_HOST_PAYLOAD_FILE must contain __TEST_HOSTNAME__ and __TEST_MAC__" unless payload.include?(@hostname) && payload.include?(@mac)

    parsed_payload = JSON.parse(payload)
    # Foreman renders unattended provisioning templates only while the host is
    # in build mode. The test host is deleted immediately after this request.
    parsed_payload["build"] = true
    response = foreman_request(Net::HTTP::Post, "/api/hosts", JSON.generate(parsed_payload))
    raise "Foreman host creation failed (HTTP #{response.code}): #{response.body}" unless response.code == "201"

    @host_id = JSON.parse(response.body).fetch("id")
  end

  def delete_test_host
    raise "Refusing to delete a non-test host" unless @hostname.start_with?("codex-proxmox-acceptance-")

    response = foreman_request(Net::HTTP::Delete, "/api/hosts/#{@host_id}")
    raise "Foreman test-host deletion failed (HTTP #{response.code}): #{response.body}" unless response.code.to_i.between?(200, 299)
  ensure
    @host_id = nil
  end

  def foreman_request(request_class, path, body = nil)
    uri = URI.parse("#{@api_base_url}#{path}")
    request = request_class.new(uri)
    request["Accept"] = "application/json"
    request["Content-Type"] = "application/json" if body
    request.body = body if body

    if ENV["FOREMAN_API_TOKEN"]
      request["Authorization"] = "Bearer #{ENV.fetch('FOREMAN_API_TOKEN')}"
    else
      request.basic_auth(ENV.fetch("FOREMAN_API_USERNAME"), ENV.fetch("FOREMAN_API_PASSWORD"))
    end

    Net::HTTP.start(
      uri.host,
      uri.port,
      use_ssl: uri.scheme == "https",
      verify_mode: ENV["FOREMAN_API_VERIFY_TLS"] == "true" ? OpenSSL::SSL::VERIFY_PEER : OpenSSL::SSL::VERIFY_NONE
    ) { |http| http.request(request) }
  end

  def answer_adapter_request(payload)
    remote_payload = "/tmp/proxmox-answer-acceptance-#{SecureRandom.hex(8)}.json"
    encoded_payload = Base64.strict_encode64(payload)

    response = Net::SSH.start(
      ENV.fetch("TARGET_HOST"),
      ENV.fetch("SPEC_SSH_USER", "ec2-user"),
      keys: [ENV.fetch("SSH_PRIVATE_KEY_FILE")],
      verify_host_key: :never,
      encryption: %w[aes256-ctr aes192-ctr aes128-ctr]
    ) do |ssh|
      command = "printf %s #{encoded_payload} | base64 --decode > #{remote_payload} && " \
                "curl --silent --show-error --include --request POST " \
                "--header 'Content-Type: application/json' --data-binary @#{remote_payload} " \
                "http://127.0.0.1/proxmox-answer; status=$?; rm -f #{remote_payload}; exit $status"
      ssh.exec!(command)
    end

    raise "Could not start adapter request" if response.nil?

    response
  end
end
