require "json"
require "net/http"
require "openssl"
require "securerandom"
require "shellwords"
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
    result = command(
      "curl --silent --show-error --include --request POST --header 'Content-Type: application/json' " \
      "--data #{Shellwords.escape(JSON.generate(network_interfaces: [{ mac: @mac }]))} http://127.0.0.1/proxmox-answer"
    )

    expect(result.exit_status).to eq 0
    headers, body = result.stdout.split(/\r?\n\r?\n/, 2)
    expect(headers).to match(%r{^HTTP/.* 200}i)
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
    parsed_payload["build"] = false
    response = foreman_request(Net::HTTP::Post, "/api/hosts", JSON.generate(parsed_payload))
    raise "Foreman host creation failed (HTTP #{response.code}): #{response.body}" unless response.code == "201"

    @host_id = JSON.parse(response.body).fetch("id")
  end

  def delete_test_host
    raise "Refusing to delete a non-test host" unless @hostname.start_with?("codex-proxmox-acceptance-")

    response = foreman_request(Net::HTTP::Delete, "/api/hosts/#{@host_id}")
    raise "Foreman test-host deletion failed (HTTP #{response.code}): #{response.body}" unless response.code.between?(200, 299)
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
end
