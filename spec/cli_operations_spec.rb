# frozen_string_literal: true

require "spec_helper"
require "stringio"
require "tempfile"
require "net/http"

RSpec.describe "Operational CLI" do
  let(:output) { StringIO.new }
  let(:error) { StringIO.new }
  let(:cli) { Gritz::CLI.new(stdout: output, stderr: error, env: {}) }
  let(:status) do
    { pid: 120, owner_pid: 119, state: "running", workers: [
      { pid: 121, index: 0, state: "ready", rss_bytes: 4_194_304, pss_bytes: 2_097_152 },
      { pid: 122, index: 1, state: "ready" }
    ] }
  end
  let(:http) { instance_double(Net::HTTP) }

  def serve_status(body = JSON.generate(status), code: "200")
    response = Net::HTTPResponse.new("1.1", code, "fixture")
    allow(response).to receive(:read_body).and_yield(body)
    allow(http).to receive(:start).and_yield(http)
    allow(http).to receive(:request).and_yield(response)
  end

  before do
    expect(Gritz::Configuration).not_to receive(:load)
    expect(Gritz::ForkGuard).not_to receive(:activate)
    allow(Net::HTTP).to receive(:new).with("127.0.0.1", 9090, nil).and_return(http)
    allow(http).to receive(:open_timeout=).with(2)
    allow(http).to receive(:read_timeout=).with(2)
    allow(http).to receive(:max_retries=).with(0)
  end

  it "prints live process status and worker PSS, including unavailable readings" do
    serve_status
    expect(cli.run(["stats"])).to eq(0)
    expect(output.string).to include("running", "120", "119", "121", "PSS", "2.00 MiB", "n/a")
    expect(error.string).to eq("")
  end

  it "reads the production read-only Admin listener over HTTP" do
    allow(Net::HTTP).to receive(:new).and_call_original
    admin = Gritz::Supervisor::AdminServer.new(bind: "127.0.0.1:0", status: -> { status }, ready: -> { true },
                                               metrics: -> { "" }, logger: Logger.new(StringIO.new))
    running = true
    polling = Thread.new do
      while running
        admin.poll
        sleep 0.001
      end
    end
    expect(cli.run(["stats", "--admin-bind", admin.address])).to eq(0)
    expect(output.string).to include("PSS", "2.00 MiB")
    expect(Process).to receive(:kill).with("USR2", 119)
    expect(cli.run(["restart", "--admin-bind", admin.address])).to eq(0)
  ensure
    running = false
    polling&.join
    admin&.close
  end

  it "sends stop and reload signals to the stable lifecycle owner" do
    serve_status
    expect(Process).to receive(:kill).with("TERM", 119)
    expect(Process).to receive(:kill).with("USR2", 119)
    expect(cli.run(["stop"])).to eq(0)
    expect(cli.run(["restart"])).to eq(0)
  end

  it "signals the master when an embedded server has no lifecycle owner" do
    serve_status(JSON.generate(status.except(:owner_pid)))
    expect(Process).to receive(:kill).with("TERM", 120)
    expect(cli.run(["stop"])).to eq(0)
  end

  it "uses explicit admin settings before the environment and disables HTTP proxies" do
    serve_status
    expect(Net::HTTP).to receive(:new).with("::1", 9091, nil).and_return(http)
    command = Gritz::CLI.new(stdout: output, stderr: error, env: { "GRITZ_ADMIN_BIND" => "unusable" })
    expect(command.run(["stats", "--admin-bind", "[::1]:9091"])).to eq(0)
  end

  it "uses environment admin and PID settings without loading application configuration" do
    serve_status
    Tempfile.create("gritz-pid") do |file|
      file.write("120\n")
      file.flush
      expect(Net::HTTP).to receive(:new).with("localhost", 9092, nil).and_return(http)
      command = Gritz::CLI.new(stdout: output, stderr: error,
                               env: { "GRITZ_ADMIN_BIND" => "localhost:9092", "GRITZ_PID_FILE" => file.path })
      expect(Process).to receive(:kill).with("TERM", 119)
      expect(command.run(["stop"])).to eq(0)
    end
  end

  it "falls back to a PID file only when the Admin connection is unavailable" do
    allow(http).to receive(:start).and_raise(Errno::ECONNREFUSED)
    Tempfile.create("gritz-pid") do |file|
      file.write("120\n")
      file.flush
      expect(Process).to receive(:kill).with("USR2", 120)
      expect(cli.run(["restart", "--pid-file", file.path])).to eq(0)
      expect(output.string).to include("120", "USR2")
    end
  end

  it "refuses to signal an Admin server that does not match the supplied PID file" do
    serve_status
    Tempfile.create("gritz-pid") do |file|
      file.write("999\n")
      file.flush
      expect(Process).not_to receive(:kill)
      expect(cli.run(["stop", "--pid-file", file.path])).to eq(1)
      expect(error.string).to include("does not match")
    end
  end

  it "rejects invalid or process-group PIDs received from the Admin endpoint" do
    expect(Process).not_to receive(:kill)
    [nil, 0, -120, 1, "120", Process.pid, 2_147_483_648].each do |pid|
      serve_status(JSON.generate(status.merge(owner_pid: pid)))
      expect(cli.run(["stop"])).to eq(1), "accepted Admin PID #{pid.inspect}"
    end
    expect(error.string).to include("PID")
  end

  it "rejects malformed, oversized and non-status Admin responses without PID fallback" do
    expect(Process).not_to receive(:kill)
    ["bogus", "[]", "{}", JSON.generate(status.merge(workers: "bogus")), " " * (1_048_576 + 1)].each do |body|
      serve_status(body)
      expect(cli.run(["stop"])).to eq(1), "accepted invalid status response"
    end
    [status[:workers].first.merge(index: "0"), status[:workers].first.merge(pss_bytes: -1)].each do |worker|
      serve_status(JSON.generate(status.merge(workers: [worker])))
      expect(cli.run(["stop"])).to eq(1), "accepted invalid worker status"
    end
  end

  it "rejects redirects and HTTP errors instead of following them or falling back" do
    expect(Process).not_to receive(:kill)
    %w[301 404 500].each do |code|
      serve_status(code: code)
      expect(cli.run(["restart"])).to eq(1)
      expect(error.string).to include(code)
    end
  end

  it "reports malformed HTTP and interrupted bodies without signaling a PID fallback" do
    expect(Process).not_to receive(:kill)
    allow(http).to receive(:start).and_raise(Net::HTTPBadResponse, "invalid response")
    expect(cli.run(["stop"])).to eq(1)
    expect(error.string).to include("Invalid Admin")
    Tempfile.create("gritz-pid") do |file|
      file.write("120\n")
      file.flush
      serve_status
      allow(http).to receive(:request) do |&block|
        response = Net::HTTPResponse.new("1.1", "200", "fixture")
        allow(response).to receive(:read_body).and_raise(EOFError)
        block.call(response)
      end
      expect(cli.run(["stop", "--pid-file", file.path])).to eq(1)
    end
  end

  it "rejects a complete JSON document carried in a truncated HTTP body on the wire" do
    allow(Net::HTTP).to receive(:new).and_call_original
    allow(Process).to receive(:kill)
    body = JSON.generate(status)
    server = TCPServer.new("127.0.0.1", 0)
    address = "127.0.0.1:#{server.addr[1]}"
    responder = Thread.new do
      3.times do
        socket = server.accept
        while (line = socket.gets) && line != "\r\n"
          nil
        end
        socket.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" \
                     "Content-Length: #{body.bytesize + 10}\r\nConnection: close\r\n\r\n#{body}")
        socket.close
      end
    rescue IOError, Errno::EBADF
      nil
    end
    Tempfile.create("gritz-pid") do |file|
      file.write("120\n")
      file.flush
      results = [cli.run(["stats", "--admin-bind", address]), cli.run(["stop", "--admin-bind", address]),
                 cli.run(["restart", "--admin-bind", address, "--pid-file", file.path])]
      expect(results).to eq([1, 1, 1])
      expect(Process).not_to have_received(:kill)
    end
  ensure
    server&.close
    responder&.join
  end

  it "rejects invalid PID files without sending a process-group signal" do
    allow(http).to receive(:start).and_raise(Errno::ECONNREFUSED)
    expect(Process).not_to receive(:kill)
    Tempfile.create("gritz-pid") do |file|
      ["0", "-120", "1", "bogus", "120 other", "2_147_483_647", "2147483648", "120\n" * 50, "120#{' ' * 100}"].each do |pid|
        file.rewind
        file.truncate(0)
        file.write(pid)
        file.flush
        expect(cli.run(["stop", "--pid-file", file.path])).to eq(1), "accepted PID file #{pid.inspect}"
      end
    end
  end

  it "fails clearly when Admin is unavailable or application config is passed" do
    allow(http).to receive(:start).and_raise(Net::ReadTimeout)
    expect(cli.run(["stats"])).to eq(1)
    expect(error.string).to include("Admin")
    expect(cli.run(["stop", "-C", "application.rb"])).to eq(1)
    expect(error.string).to include("--admin-bind", "--pid-file")
  end

  it "reports stale PID files and invalid Admin addresses as command errors" do
    allow(http).to receive(:start).and_raise(Errno::ECONNREFUSED)
    Tempfile.create("gritz-pid") do |file|
      file.write("120\n")
      file.flush
      expect(Process).to receive(:kill).with("TERM", 120).and_raise(Errno::ESRCH)
      expect(cli.run(["stop", "--pid-file", file.path])).to eq(1)
      expect(error.string).to include("120")
    end
    %w[https://example.com:9090 localhost:0 localhost:65536 localhost:-1 localhost:9090/path].each do |address|
      expect(cli.run(["stats", "--admin-bind", address])).to eq(1)
    end
  end
end
