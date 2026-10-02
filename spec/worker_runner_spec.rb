# frozen_string_literal: true

require "spec_helper"
require "logger"
require "stringio"

RSpec.describe Gritz::Worker::Runner do
  before do
    @config = Gritz::Configuration.new
    @config.bind = "127.0.0.1:0"
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
    allow(Gritz::Supervisor::SignalQueue).to receive(:new).with(signals: %w[TERM INT QUIT HUP]).and_return(@queue)
    @running = false
    @adapter = double("native transport")
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

  it "preloads in the worker only when the master did not preload" do
    @config.add_preloader { @events << :preload }
    @config.preload_app = false
    expect(@runner.run).to eq(0)
    expect(@events.first(2)).to eq([:preload, [:boot, 2]])
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
    @names << "TERM"
    runner = described_class.new(index: 0, config: @config, logger: @logger)
    allow(runner).to receive(:require).with("gritz/native").and_return(true)
    expect(runner.run).to eq(0)
    expect(@events).to include([:shutdown, 0])
  end
end
