# frozen_string_literal: true

require "open3"
require "json"
require_relative "../lib/gritz/core/version"

version = Gritz::Core::VERSION
tag = ENV.fetch("GITHUB_REF_NAME", "")
abort "Tag and package version must match (expected v#{version})" unless tag == "v#{version}"

def git!(*)
  output, status = Open3.capture2e("git", *)
  abort output unless status.success?

  output
end

gem_name = File.basename(Dir[File.expand_path("../*.gemspec", __dir__)].fetch(0), ".gemspec")
response, status = Open3.capture2e("curl", "--fail", "--silent", "--show-error", "--max-time", "30",
                                   "https://rubygems.org/api/v1/versions/#{gem_name}.json")
abort "Unable to verify published versions: #{response}" unless status.success?
published = JSON.parse(response).map { |release| release.fetch("number") }
abort "No published versions; the owner performs the initial release" if published.empty?

previous = git!("tag", "--list", "v*", "--merged", "HEAD").lines.map(&:strip)
previous = previous.select do |name|
  name.match?(/\Av\d+\.\d+\.\d+\z/) && published.include?(name.delete_prefix("v")) &&
    Gem::Version.new(name.delete_prefix("v")) < Gem::Version.new(version)
end.max_by { |name| Gem::Version.new(name.delete_prefix("v")) }
changed = previous ? git!("diff", "--name-only", previous, "HEAD").lines.map(&:strip) : git!("ls-files").lines.map(&:strip)
runtime = changed.any? do |path|
  path.match?(%r{\A(?:lib/|exe/)}) && !path.end_with?("/version.rb")
end
dependency_change = previous && git!("diff", previous, "HEAD", "--", "*.gemspec").match?(/^[+-]\s*spec\.add_dependency\b/)
abort "No user-facing runtime or dependency changes; do not release documentation-only changes" unless runtime || dependency_change

puts "Release #{tag} validated"
