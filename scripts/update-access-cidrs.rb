#!/usr/bin/env ruby
# frozen_string_literal: true

path = ARGV.fetch(0)
ip = ARGV.fetch(1)

content = File.read(path)

%w[admin_cidrs ssh_cidrs].each do |key|
  pattern = /^(\s*#{Regexp.escape(key)}\s*=\s*)\[[^\]]*\]/
  raise "Missing #{key} in #{path}" unless content.match?(pattern)

  content.sub!(pattern) { "#{$1}[\"#{ip}/32\"]" }
end

File.write(path, content)
