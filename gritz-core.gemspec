# frozen_string_literal: true

require_relative "lib/gritz/core/version"

Gem::Specification.new do |spec|
  spec.name = "gritz-core"
  spec.version = Gritz::Core::VERSION
  spec.authors = ["Yudai Takada"]
  spec.email = ["t.yudai92@gmail.com"]
  spec.description = "Transport-independent controllers, routing, middleware, configuration and testing for Gritz."
  spec.summary = "Transport-independent controllers and middleware for Gritz"
  spec.homepage = "https://github.com/gritzrpc/gritz-core"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.3"
  spec.metadata = {
    "allowed_push_host" => "https://rubygems.org",
    "source_code_uri" => spec.homepage,
    "documentation_uri" => "https://gritzrpc.github.io/gritz/",
    "changelog_uri" => "#{spec.homepage}/blob/main/CHANGELOG.md",
    "rubygems_mfa_required" => "true"
  }
  spec.files = Dir.chdir(__dir__) { Dir["lib/**/*.rb", "exe/*", "README.md", "LICENSE.txt", "CHANGELOG.md"] }
  spec.require_paths = ["lib"]
  spec.bindir = "exe"
  spec.executables = ["gritz-migrate-gruf"]
  spec.add_dependency "fiddle", ">= 1.1", "< 3"
  spec.add_dependency "google-protobuf", ">= 4.33", "< 5"
  spec.add_dependency "json", ">= 2.7", "< 3"
  spec.add_dependency "logger", ">= 1.6", "< 2"
  spec.add_dependency "zeitwerk", ">= 2.7", "< 3"
end
