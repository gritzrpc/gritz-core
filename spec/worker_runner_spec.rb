# frozen_string_literal: true

require "spec_helper"
require "logger"
require "stringio"
require "timeout"

RSpec.describe Gritz::Worker::Runner do
  before do
    @config = Gritz::Configuration.new
    @config.workers = 1
    @config.bind = "127.0.0.1:0"
    @config.admin_bind = "127.0.0.1:0"
    @config.status_interval = 0.001
    @log_output = StringIO.new
    @logger = Logger.new(@log_output)
    @events = []
    @names = []
    @signal_read, @signal_write = IO.pipe
    @status_read, @status_write = IO.pipe
    @statuses = Gritz::Supervisor::StatusChannel.new(@status_read)
    @queue = double("signal queue", io: @signal_read, close: nil)
    allow(@queue).to receive(:drain) { @names.shift(@names.length) }
    stub_const("Gritz::Supervisor::SignalQueue", Class.new)
    allow(Gritz::Supervisor::SignalQueue).to receive(:new).with(signals: %w[TERM INT QUIT HUP USR1 USR2]).and_return(@queue)
    @running = false
    @adapter = double("native transport")
    allow(@adapter).to receive(:update_health).and_return(true)
    allow(@adapter).to receive(:drain!)
    allow(@adapter).to receive(:bind) {
      @events << :bind
      50_051
    }
    allow(@adapter).to receive(:start) {
      @events << :start
      @running = true
    }
    allow(@adapter).to receive(:running?) { @running }
    allow(@adapter).to receive(:stop) {
      @events << :stop
      @running = false
    }
    allow(@adapter).to receive(:kill) {
      @events << :kill
      @running = false
    }
    allow(@adapter).to receive(:stats) do
      @names << "TERM"
      { inflight: 0, busy: 0, capacity: 16, requests_total: 3, oldest_inflight_age: 0 }
    end
    stub_const("Gritz::Transport", Module.new)
    stub_const("Gritz::Transport::Native", Class.new)
    allow(Gritz::Transport::Native).to receive(:new).and_return(@adapter)
    @runner = described_class.new(index: 2, status_io: @status_write, config: @config, logger: @logger)
    allow(@runner).to receive(:require).with("gritz/native").and_return(true)
    @config.add_hook(:on_worker_boot) { |index| @events << [:boot, index] }
    @config.add_hook(:on_worker_shutdown) { |index| @events << [:shutdown, index] }
  end

  after do
    [@signal_read, @signal_write, @status_write].each { |io| io.close unless io.closed? }
    @statuses.close
  end

  it "runs hooks, serves, reports ready and drains with the configured deadline" do
    now = Time.now
    allow(Time).to receive(:now).and_return(now)
    expect(@adapter).to receive(:stop).with(deadline: now + @config.shutdown_timeout) {
      @events << :stop
      @running = false
    }
    expect(IO).not_to receive(:select)
    expect(@runner.run).to eq(0)
    expect(@events).to eq([[:boot, 2], :bind, :start, :stop, [:shutdown, 2]])
    rows = @statuses.read
    expect(rows.map { |row| row[:state] }).to eq(%w[booting ready draining stopped])
    expect(rows[1]).to include(pid: Process.pid, index: 2, inflight: 0, busy_threads: 0, capacity: 16, requests_total: 3, port: 50_051)
    expect(rows[1][:ts]).to be_a(Numeric)
    expect(@log_output.string).to include("Gritz #{Gritz::Core::VERSION} listening on 127.0.0.1:50051")
    expect(@queue).to have_received(:close)
    expect(@status_write).to be_closed
  end

  it "selects the Async adapter and passes the inherited listener" do
    @config.transport = :async
    stub_const("Gritz::Transport::Async", Class.new)
    allow(Gritz::Transport::Async).to receive(:new).and_return(@adapter)
    listener = double("inherited socket")
    @runner = described_class.new(index: 2, status_io: @status_write, config: @config, logger: @logger, listener:)
    allow(@runner).to receive(:require).with("gritz/async").and_return(true)
    expect(@adapter).to receive(:bind).with(listener).and_return(50_051)
    expect(Gritz::Transport::Native).not_to receive(:new)
    expect(@runner.run).to eq(0)
    expect(Gritz::Transport::Async).to have_received(:new)
  end

  it "preloads in the worker only when the master did not preload" do
    @config.add_preloader { @events << :preload }
    @config.preload_app = false
    expect(@runner.run).to eq(0)
    expect(@events.first(2)).to eq([:preload, [:boot, 2]])
  end

  it "constructs a custom recorder after boot hooks and closes it after final RPC deltas and shutdown hooks" do
    recorder = Gritz::Metrics::Recorder.new
    @config.metrics_recorder_factory = lambda { |worker:|
      expect(@events).to include([:boot, worker])
      recorder
    }
    expect(recorder).to receive(:close) { |timeout:|
      expect(@events).to include([:shutdown, 2])
      expect(recorder.take_delta).to be_nil
      expect(timeout).to be_between(0, @config.shutdown_timeout)
    }
    expect(@runner.run).to eq(0)
    expect(@runner.instance_variable_get(:@recorder)).to equal(recorder)
  end

  it "does not repeat preloading performed by the master" do
    @config.add_preloader { @events << :preload }
    expect(@runner.run).to eq(0)
    expect(@events).not_to include(:preload)
  end

  it "emits periodic heartbeats from the main loop" do
    count = 0
    allow(@adapter).to receive(:stats) do
      count += 1
      @names << "TERM" if count == 3
      { inflight: 0, busy: 0, capacity: 16, requests_total: count, oldest_inflight_age: 0 }
    end
    expect(@runner.run).to eq(0)
    ready = @statuses.read.select { |row| row[:state] == "ready" }
    expect(ready.size).to eq(3)
    expect(ready.map { |row| row[:ts] }).to eq(ready.map { |row| row[:ts] }.sort)
  end

  it "batches RPC metrics at the status interval, retries pending writes and flushes final observations" do
    @config.status_interval = 0.2
    ticks = 0
    allow(@runner).to receive(:monotonic) { ticks / 100.0 }
    allow(@adapter).to receive(:stats).and_return({})
    recorder = @runner.instance_variable_get(:@recorder)
    record = -> { recorder.record_rpc(service: "test.Echo", method: "Echo", code: 0, duration: 0.01, requests: 1, responses: 1) }
    allow(IO).to receive(:select) do
      ticks += 5
      record.call
      @names << "TERM" if ticks >= 60
    end
    @config.add_hook(:on_worker_shutdown) { record.call }
    rejected = false
    channel = @runner.instance_variable_get(:@status)
    allow(channel).to receive(:write).and_wrap_original do |original, row|
      if row[:type] == "metrics" && !rejected
        rejected = true
        false
      else
        original.call(row)
      end
    end

    expect(@runner.run).to eq(0)
    packets = @statuses.read.select { |row| row[:type] == "metrics" }
    expect(packets.map { |row| row[:seq] }).to eq([1, 2, 3])
    expect(packets.map { |row| row[:delta][:rpc].first[:count] }).to eq([4, 4, 5])
  end

  it "reopens logs without closing the output and stops immediately on QUIT" do
    allow(@adapter).to receive(:stats) do
      @names.push("HUP", "QUIT")
      {}
    end
    expect(@logger).to receive(:reopen).and_call_original
    expect(@runner.run).to eq(0)
    expect(@events).to include(:kill)
    expect(@events).not_to include(:stop)
    expect(@log_output).not_to be_closed
  end

  it "reports startup failures and still runs the shutdown hook once" do
    allow(@adapter).to receive(:bind).and_raise(ArgumentError, "address unavailable")
    expect(@runner.run).to eq(1)
    expect(@events.count { |event| event == [:shutdown, 2] }).to eq(1)
    expect(@statuses.read).to include(include(state: "failed", error: "address unavailable"))
    expect(@log_output.string).to include("address unavailable")
  end

  it "turns an actual abort in a boot hook into a failed exit and cleans up once" do
    @config.add_hook(:on_worker_boot) { abort "aborted worker boot" }
    status = nil
    expect { status = @runner.run }.to output("aborted worker boot\n").to_stderr
    expect(status).to eq(1)
    expect(@events.count { |event| event == [:shutdown, 2] }).to eq(1)
    expect(@statuses.read).to include(include(state: "failed", error: "aborted worker boot"))
    expect(@queue).to have_received(:close)
    expect(@status_write).to be_closed
  end

  it "runs shutdown cleanup when worker preloading raises a syntax error" do
    @config.add_preloader { raise SyntaxError, "bad application syntax" }
    @config.preload_app = false
    expect(@runner.run).to eq(1)
    expect(@events).to eq([[:shutdown, 2]])
    expect(@statuses.read).to include(include(state: "failed", error: "bad application syntax"))
    expect(@queue).to have_received(:close)
    expect(@status_write).to be_closed
  end

  it "closes a bound transport when startup fails before it is running" do
    allow(@adapter).to receive(:start).and_raise("server startup failed")
    expect(@runner.run).to eq(1)
    expect(@events).to eq([[:boot, 2], :bind, :kill, [:shutdown, 2]])
    expect(@statuses.read.last).to include(state: "stopped", exit_status: 1)
  end

  it "cleans up an actual abort in the shutdown hook without rerunning it" do
    @config.add_hook(:on_worker_shutdown) { abort "aborted worker shutdown" }
    status = nil
    expect { status = @runner.run }.to output("aborted worker shutdown\n").to_stderr
    expect(status).to eq(1)
    expect(@events.count { |event| event == [:shutdown, 2] }).to eq(1)
    expect(@statuses.read.last).to include(state: "stopped", exit_status: 1)
    expect(@queue).to have_received(:close)
    expect(@status_write).to be_closed
  end

  it "detects unexpected transport exit and cleans up failures during stop" do
    allow(@adapter).to receive(:running?).and_return(false)
    expect(@runner.run).to eq(1)
    expect(@log_output.string).to include("stopped unexpectedly")
  end

  it "kills a transport whose graceful stop failed and records a failing exit" do
    allow(@adapter).to receive(:stop).and_raise("stop failed")
    expect(@runner.run).to eq(1)
    expect(@events).to include(:kill, [:shutdown, 2])
    expect(@statuses.read.last).to include(state: "stopped", exit_status: 1)
  end

  it "closes inherited resources even if status gathering fails" do
    allow(@adapter).to receive(:stats).and_raise("stats failed")
    expect(@runner.run).to eq(1)
    expect(@events).to include(:kill, [:shutdown, 2])
    expect(@statuses.read.last).to include(state: "stopped", exit_status: 1)
    expect(@status_write).to be_closed
    expect(@queue).to have_received(:close)
  end

  it "exits safely when the master closes the status pipe" do
    @statuses.close
    expect(@runner.run).to eq(1)
    expect(@events).to include(:kill, [:shutdown, 2])
    expect(@log_output.string).to include("worker status pipe closed")
  end

  it "supports single-process use without a status pipe" do
    @config.workers = 0
    @config.drain_delay = 0
    @names << "TERM"
    runner = described_class.new(index: 0, config: @config, logger: @logger)
    allow(runner).to receive(:require).with("gritz/native").and_return(true)
    expect(runner.run).to eq(0)
    expect(@events).to include([:shutdown, 0])
  end

  it "warns and keeps single-process readiness after USR1 instead of applying an internal worker drain" do
    @config.workers = 0
    @config.drain_delay = 0
    count = 0
    allow(@adapter).to receive(:stats) do
      count += 1
      @names << (count == 1 ? "USR1" : "TERM")
      { requests_total: 0 }
    end
    expect(@runner.run).to eq(0)
    rows = @statuses.read
    expect(rows.count { |row| row[:state] == "ready" }).to eq(2)
    expect(@adapter).to have_received(:drain!).once
    expect(@log_output.string).to include("USR1 requires workers > 0")
  end

  it "keeps single-process status flowing through the drain delay without extending it on repeated TERM" do
    @config.workers = 0
    @config.drain_delay = 0.02
    @config.shutdown_timeout = 0.1
    started = nil
    allow(@adapter).to receive(:drain!) { started = Process.clock_gettime(Process::CLOCK_MONOTONIC) }
    expect(@adapter).to receive(:stop) do |deadline:|
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be >= @config.drain_delay
      expect(deadline - Time.now).to be_within(0.02).of(@config.shutdown_timeout)
      @running = false
    end
    expect(Timeout.timeout(0.5) { @runner.run }).to eq(0)
    draining = @statuses.read.select { |row| row[:state] == "draining" }
    expect(draining.size).to be > 1
    expect(draining).to all(include(healthy: false))
    expect(@adapter).to have_received(:drain!).once
  end

  it "publishes failing health checks and keeps draining sticky after USR1" do
    @config.health_checks[:database] = -> { raise "database unavailable" }
    count = 0
    allow(@adapter).to receive(:stats) do
      count += 1
      @names << (count == 1 ? "USR1" : "TERM")
      { requests_total: 0 }
    end
    expect(@adapter).to receive(:update_health).with(ready: true, checks: { database: false }).at_least(:once).and_return(false)
    expect(@runner.run).to eq(0)
    rows = @statuses.read
    expect(rows.find { |row| row[:state] == "ready" }).to include(healthy: false, checks: { database: false })
    expect(rows.drop_while { |row| row[:state] != "draining" }.map { |row| row[:state] }).not_to include("ready")
    expect(@adapter).to have_received(:drain!).at_least(:once)
  end

  it "flushes final RPC deltas before closing the pipe" do
    @config.add_hook(:on_worker_shutdown) do
      @runner.instance_variable_get(:@recorder).record_rpc(service: "test.Echo", method: "Echo", code: 0, duration: 0.01, requests: 1, responses: 1)
    end
    expect(@runner.run).to eq(0)
    packets = @statuses.read.select { |row| row[:type] == "metrics" }
    expect(packets.map { |row| row[:seq] }).to eq([1])
    expect(packets.first[:delta][:rpc].first[:count]).to eq(1)
  end

  it "includes overload rejections occurring during graceful transport shutdown in the final delta" do
    rejected_total = 1
    allow(@adapter).to receive(:stats) do
      @names << "TERM"
      { rejected_total: rejected_total }
    end
    allow(@adapter).to receive(:stop) do
      rejected_total = 4
      @running = false
    end
    expect(@runner.run).to eq(0)
    packets = @statuses.read.select { |row| row[:type] == "metrics" }
    expect(packets.sum { |row| row[:delta][:rejected] }).to eq(4)
  end

  it "does not raise when the flush deadline passes between checking it and waiting for a writable pipe" do
    recorder = @runner.instance_variable_get(:@recorder)
    recorder.record_rpc(service: "test.Echo", method: "Echo", code: 0, duration: 0.01, requests: 1, responses: 1)
    channel = double("backpressured status channel", io: @status_write, flush: false, write: false, closed?: false, close: nil)
    @runner.instance_variable_set(:@status, channel)
    @runner.instance_variable_set(:@stop_deadline, 1.0)
    allow(@runner).to receive(:monotonic).and_return(0.0, 1.1)
    expect { @runner.send(:finish) }.not_to raise_error
  end

  it "retains rejected metric writes and flushes every final chunk across partial pipe writes" do
    @config.add_hook(:on_worker_shutdown) do
      recorder = @runner.instance_variable_get(:@recorder)
      400.times do |index|
        recorder.record_rpc(service: "test.Echo", method: "Method#{index}", code: 0, duration: 0.01, requests: 1, responses: 1)
      end
    end
    allow(@status_write).to receive(:write_nonblock).and_wrap_original do |original, bytes, **options|
      original.call(bytes.byteslice(0, 97), **options)
    end
    channel = @runner.instance_variable_get(:@status)
    rejected = false
    allow(channel).to receive(:write).and_wrap_original do |original, row|
      if row[:type] == "metrics" && !rejected
        rejected = true
        false
      else
        original.call(row)
      end
    end
    rows = []
    reader = Thread.new do
      until @statuses.closed?
        rows.concat(@statuses.read)
        @status_read.wait_readable(0.01) unless @status_read.closed?
      end
    end
    expect(@runner.run).to eq(0)
    expect(reader.join(2)).not_to be_nil
    packets = rows.select { |row| row[:type] == "metrics" }
    expect(packets.size).to be > 1
    expect(packets.map { |row| row[:seq] }).to eq((1..packets.size).to_a)
    expect(packets.sum { |row| row[:delta][:rpc].sum { |rpc| rpc[:count] } }).to eq(400)
    expect(rows.last[:state]).to eq("stopped")
  ensure
    @status_write.close unless @status_write.closed?
    reader&.join(2)
  end
end
