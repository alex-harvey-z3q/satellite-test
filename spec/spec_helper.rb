require "serverspec"

set :backend, :ssh
set :host, ENV.fetch("TARGET_HOST")
set :ssh_options,
    user: ENV.fetch("SPEC_SSH_USER", "ec2-user"),
    keys: [ENV.fetch("SSH_PRIVATE_KEY_FILE")],
    verify_host_key: :never,
    encryption: %w[aes256-ctr aes192-ctr aes128-ctr]
set :sudo_options, "-n"
