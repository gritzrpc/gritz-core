# frozen_string_literal: true

require "spec_helper"
require "open3"
require "tmpdir"

RSpec.describe "Release preparation" do
  it "packages one gem from its own repository" do
    gemspecs = Open3.capture2("git", "ls-files", "--", "*.gemspec").first.lines.map(&:strip)
    expect(gemspecs).to eq(["gritz-core.gemspec"])
    spec = Gem::Specification.load("gritz-core.gemspec")
    expect(spec.version.to_s).to eq(Gritz::Core::VERSION)
    expect(spec.files).to include("lib/gritz/core.rb", "lib/gritz/controller.rb", "CHANGELOG.md")
    expect(spec.homepage).to eq("https://github.com/gritzrpc/gritz-core")
    expect(spec.metadata["rubygems_mfa_required"]).to eq("true")
    expect(spec.files.none? { |file| file.start_with?("spec/", ".idea/", "spikes/") }).to be true
    expect(spec.dependencies.map(&:name)).not_to include("grpc", "gritz-native")
  end

  it "extracts only the requested changelog version and rejects empty or absent releases" do
    script = File.expand_path("../tools/release_notes.rb", __dir__)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "CHANGELOG.md")
      File.write(path, "# Changelog\n\n## Unreleased\n\n## 0.1.0\n\nInitial release.\n\n## 0.0.1\n\nOld.\n")
      output, status = Open3.capture2e("ruby", script, "0.1.0", path)
      expect(status.success?).to be true
      expect(output.strip).to eq("Initial release.")
      _, status = Open3.capture2e("ruby", script, "0.2.0", path)
      expect(status.success?).to be false
      _, status = Open3.capture2e("ruby", script, "Unreleased", path)
      expect(status.success?).to be false
    end
  end

  it "refuses a tag that differs from the package version" do
    script = File.expand_path("../tools/check_release.rb", __dir__)
    output, status = Open3.capture2e({ "GITHUB_REF_NAME" => "v9.9.9" }, "ruby", script)
    expect(status.success?).to be false
    expect(output).to include("version")
  end

  it "rejects documentation and version-only releases but permits runtime changes" do
    script = File.expand_path("../tools/check_release.rb", __dir__)
    Dir.mktmpdir do |dir|
      git = lambda do |*args|
        output, status = Open3.capture2e("git", *args, chdir: dir)
        raise output unless status.success?
      end
      git.call("init", "-q")
      git.call("config", "user.name", "Release Test")
      git.call("config", "user.email", "release@example.test")
      Dir.mkdir(File.join(dir, "lib"))
      File.write(File.join(dir, "lib/server.rb"), "puts 'hello'\n")
      git.call("add", ".")
      git.call("commit", "-qm", "initial")
      git.call("tag", "v0.0.1")
      File.write(File.join(dir, "README.md"), "Guide\n")
      File.write(File.join(dir, "lib/version.rb"), "VERSION = '0.1.0'\n")
      git.call("add", ".")
      git.call("commit", "-qm", "docs")
      env = { "GITHUB_REF_NAME" => "v0.1.0" }
      output, status = Open3.capture2e(env, "ruby", script, chdir: dir)
      expect(status.success?).to be false
      expect(output).to include("documentation-only")
      File.write(File.join(dir, "lib/server.rb"), "puts 'new behavior'\n")
      git.call("add", ".")
      git.call("commit", "-qm", "runtime")
      output, status = Open3.capture2e(env, "ruby", script, chdir: dir)
      expect(status.success?).to eq(true), output
    end
  end
end
