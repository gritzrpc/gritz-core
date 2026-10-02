# frozen_string_literal: true

require "spec_helper"
require "stringio"
require "tempfile"
require "open3"
require "io/wait"

RSpec.describe "CLI" do
  def run_cli(source, *args, env: {})
    output = StringIO.new
    error = StringIO.new
    status = Tempfile.create(["gritz", ".rb"]) do |file|
      file.write(source)
      file.flush
      Gritz::CLI.new(stdout: output, stderr: error, env: env).run([*args, "-C", file.path])
    end
    [status, output.string, error.string]
  end

  it "prints usage and version without opening sockets" do
    io = StringIO.new
    cli = Gritz::CLI.new(stdout: io, stderr: StringIO.new, env: {})
    expect(cli.run(["--version"])).to eq(0)
    expect(io.string).to include("0.1.0")
    expect(cli.run(["--help"])).to eq(0)
    expect(io.string).to include("routes", "start")
  end

  it "returns actionable errors for bad input and config" do
    expect(run_cli("threads 0", "routes")).to match([1, "", /threads/])
    expect(run_cli("", "bogus")).to match([1, "", /Unknown command/])
    expect(run_cli("", "routes", "--bogus")).to match([1, "", /invalid option/])
    expect(run_cli("", "routes", "extra")).to match([1, "", /Unexpected argument/])
  end

  it "fails before binding for features outside the initial release" do
    expect(run_cli("workers 2", "start")).to match([1, "", /workers 0/])
    expect(run_cli("transport :async", "start")).to match([1, "", /native/])
    expect(run_cli("worker_recycle max_requests: 10", "start")).to match([1, "", /worker_recycle/])
  end

  it "lets command line settings override invalid environment values at the value level" do
    status, = run_cli("", "routes", "--threads", "3", env: { "GRITZ_THREADS" => "0" })
    expect(status).to eq(0)
  end
end
