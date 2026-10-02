# frozen_string_literal: true

require "spec_helper"
require "logger"
require "stringio"
require "io/wait"

RSpec.describe "Supervisor" do
  it "coalesces signals through a self-pipe and restores the previous handler" do
    previous = Signal.trap("USR1", "IGNORE")
    queue = Gritz::Supervisor::SignalQueue.new(signals: %w[USR1])
    Process.kill("USR1", Process.pid)
    expect(queue.io.wait_readable(1)).not_to be_nil
    expect(queue.drain).to eq(["USR1"])
    expect(queue.drain).to eq([])
    queue.close
    expect(Signal.trap("USR1", "IGNORE")).to eq("IGNORE")
  ensure
    queue&.close
    Signal.trap("USR1", previous) if previous
  end

  it "tracks startup and heartbeat deadlines independently of worker timestamps" do
    reader, writer = IO.pipe
    handle = Gritz::Supervisor::WorkerHandle.new(pid: 123, index: 0, status_io: reader, now: 10)
    expect(handle.state).to eq("booting")
    handle.update({ state: "ready", ts: -500, port: 50_051, inflight: 2 }, now: 11)
    expect(handle.last_seen).to eq(11)
    expect(handle.to_h).to include(pid: 123, index: 0, state: "ready", port: 50_051, inflight: 2)
    expect { handle.update({ state: "unknown" }, now: 12) }.to raise_error(Gritz::ConfigurationError)
  ensure
    handle&.close
    writer&.close
  end

  it "starts workers, reports readiness, and reaps them after a graceful shutdown" do
    config = Gritz::Configuration.new
    config.workers = 2
    config.controllers = [Class.new]
    config.drain_delay = 0
    config.shutdown_timeout = 0.5
    config.status_interval = 0.02
    reader, writer = IO.pipe
    logger = Logger.new(StringIO.new)
    runner = Class.new do
      def initialize(status_io:, **)
        @io = status_io
      end

      def run
        queue = Gritz::Supervisor::SignalQueue.new(signals: %w[TERM INT QUIT])
        channel = Gritz::Supervisor::StatusChannel.new(@io)
        channel.write(pid: Process.pid, state: "ready", port: 50_051, inflight: 0)
        loop do
          break unless queue.drain.empty?

          queue.io.wait_readable(0.02)
          channel.write(pid: Process.pid, state: "ready", port: 50_051, inflight: 0)
        end
        0
      ensure
        queue&.close
        channel&.close
      end
    end
    stub_const("Gritz::Worker::Runner", runner)
    master = Gritz::Supervisor::Master.new(config, logger: logger, status_io: writer)
    allow(master).to receive(:require).with("gritz/native").and_return(true)
    thread = Thread.new { master.run }
    channel = Gritz::Supervisor::StatusChannel.new(reader)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
    loop do
      snapshots = channel.read
      break if snapshots.any? { |snapshot| snapshot[:workers].size == 2 && snapshot[:workers].all? { |worker| worker[:state] == "ready" } }
      raise "workers never ready" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      reader.wait_readable(0.02)
    end
    Process.kill("TERM", Process.pid)
    expect(thread.join(3)).not_to be_nil
    expect(thread.value).to eq(0)
    expect(master.workers).to be_empty
  ensure
    if thread&.alive?
      Process.kill("QUIT", Process.pid)
      thread.join(2)
    end
    reader&.close unless reader&.closed?
    writer&.close unless writer&.closed?
  end
end
