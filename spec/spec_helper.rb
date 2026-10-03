# frozen_string_literal: true

if ENV["COVERAGE"]
  require "simplecov"
  SimpleCov.start do
    track_files "lib/**/*.rb"
    add_filter "/version.rb"
    add_filter "/testing/transport_contract.rb" # Shared RSpec examples run in the adapter suites.
    add_filter { |file| !file.filename.start_with?("#{File.expand_path('../lib', __dir__)}/") }
    enable_coverage :branch
    minimum_coverage line: 90
  end
end

require "gritz/core"

RSpec.configure do |config|
  config.example_status_persistence_file_path = ".rspec_status"
  config.disable_monkey_patching!
  config.expect_with :rspec do |expectations|
    expectations.syntax = :expect
  end
end
