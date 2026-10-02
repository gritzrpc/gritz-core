# frozen_string_literal: true

require "spec_helper"
require "socket"
require "logger"
require "stringio"

RSpec.describe Gritz::Supervisor::AdminServer do
  def request(path, method: "GET")
    socket = TCPSocket.new("127.0.0.1", @server.io.addr[1])
    socket.write("#{method} #{path} HTTP/1.1\r\nHost: localhost\r\n\r\n")
    result = +""
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1
    loop do
      @server.poll
      chunk = socket.read_nonblock(4096, exception: false)
      break if chunk.nil?

      result << chunk if chunk.is_a?(String)
      raise "admin stalled" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    end
    result
  ensure
    socket&.close
  end

  before do
    @ready = false
    @server = described_class.new(bind: "127.0.0.1:0", status: -> { { state: "running", workers: [] } },
                                  ready: -> { @ready }, metrics: -> { "gritz_rejected_total 3\n" }, logger: Logger.new(StringIO.new))
  end

  after { @server.close }

  it "serves liveness independently of readiness and exports status and metrics" do
    expect(request("/livez")).to start_with("HTTP/1.1 200")
    expect(request("/readyz")).to start_with("HTTP/1.1 503")
    @ready = true
    expect(request("/readyz")).to start_with("HTTP/1.1 200")
    expect(request("/status")).to include('"state":"running"')
    expect(request("/metrics")).to include("gritz_rejected_total 3\n")
    expect(request("/unknown")).to start_with("HTTP/1.1 404")
    expect(request("/livez", method: "POST")).to start_with("HTTP/1.1 405")
  end

  it "does not let a partial or oversized request block probes" do
    stalled = TCPSocket.new("127.0.0.1", @server.io.addr[1])
    stalled.write("GET /livez HTTP/1.1\r\nHost:")
    @server.poll
    expect(request("/livez")).to start_with("HTTP/1.1 200")
    stalled.write("x" * 8192)
    response = +""
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1
    loop do
      @server.poll
      chunk = stalled.read_nonblock(4096, exception: false)
      break if chunk.nil?

      response << chunk if chunk.is_a?(String)
      raise "oversized admin request stalled" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    end
    expect(response).to start_with("HTTP/1.1 431")
    expect(@server.address).to eq("127.0.0.1:#{@server.io.addr[1]}")
  ensure
    stalled&.close
  end

  it "keeps serving probes after a queued connection aborts before accept" do
    aborted = false
    allow(@server.io).to receive(:accept_nonblock).and_wrap_original do |original, **options|
      unless aborted
        aborted = true
        raise Errno::ECONNABORTED
      end
      original.call(**options)
    end
    expect(request("/livez")).to start_with("HTTP/1.1 200")
  end
end
