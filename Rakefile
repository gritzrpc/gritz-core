# frozen_string_literal: true

require "rspec/core/rake_task"
require "fileutils"

RSpec::Core::RakeTask.new(:spec)
task default: :spec

desc "Build the gritz-core release package"
task :build do
  FileUtils.mkdir_p("pkg")
  sh "gem", "build", "--strict", "gritz-core.gemspec", "--output", "pkg/gritz-core.gem"
end

desc "Publish the tagged package using trusted publisher credentials"
task release: :build do
  abort "Use the tag-triggered release workflow" unless ENV["GITHUB_ACTIONS"] == "true" && ENV["GITHUB_REF_TYPE"] == "tag"

  sh "ruby", "tools/check_release.rb"
  sh "gem", "push", "pkg/gritz-core.gem"
end
