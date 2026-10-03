# frozen_string_literal: true

require "spec_helper"
require "json"
require "tmpdir"
require "rbconfig"
require "logger"
require "stringio"
require "io/wait"

RSpec.describe Gritz::Supervisor::Launcher do
  around do |example|
    Dir.mktmpdir("gritz-launcher") do |dir|
      @path = File.join(dir, "application.json")
      @pid_path = File.join(dir, "application.pid")
      @log = StringIO.new
      @reader, @writer = IO.pipe
      @statuses = Gritz::Supervisor::StatusChannel.new(@reader)
      @launcher = described_class.new(
        command: [RbConfig.ruby, "-I", File.expand_path("../lib", __dir__),
                  File.expand_path("fixtures/launcher_master.rb", __dir__), @path],
        logger: Logger.new(@log), status_io: @writer,
        startup_timeout: example.metadata.fetch(:startup_timeout, 60)
      )
      example.run
    ensure
      if @thread&.alive?
        @launcher.send(:begin_shutdown)
        @thread.join(3)
      end
      @statuses&.close
      @writer&.close unless @writer&.closed?
    end
  end

  def configure(version: "one", mode: nil, **options)
    File.write(@path, JSON.generate({ version:, mode:, pid_file: @pid_path }.merge(options)))
  end

  def wait_status(timeout: 3)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      @statuses.read.each { |row| @snapshot = row }
      return @snapshot if @snapshot && yield(@snapshot)
      raise "launcher exited: #{@log.string}" if @thread && !@thread.alive?
      raise "status timeout: #{@snapshot.inspect}\n#{@log.string}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      @reader.wait_readable(0.02)
    end
  end

  def start
    @thread = Thread.new { @launcher.run }
    wait_status { |row| row[:state] == "running" && row[:workers].any? { |worker| worker[:state] == "ready" } }
  end

  it "keeps one owner, reloads a fresh direct child, updates the PID file and reaps retired generations" do
    configure
    first = start.fetch(:pid)
    expect(Integer(File.read(@pid_path))).to eq(first)
    configure(version: "two")
    Process.kill("USR2", Process.pid)
    second = wait_status { |row| row[:pid] != first && row[:workers].all? { |worker| worker[:version] == "two" } }.fetch(:pid)
    expect(Integer(File.read(@pid_path))).to eq(second)
    expect { Process.kill(0, first) }.to raise_error(Errno::ESRCH)
    configure(version: "three")
    Process.kill("USR2", second)
    third = wait_status { |row| row[:pid] != second && row[:workers].all? { |worker| worker[:version] == "three" } }.fetch(:pid)
    expect(Integer(File.read(@pid_path))).to eq(third)
    Process.kill("TERM", Process.pid)
    expect(@thread.join(3)).not_to be_nil
    expect(@thread.value).to eq(0)
    expect { Process.kill(0, third) }.to raise_error(Errno::ESRCH)
    expect(File.exist?(@pid_path)).to be false
  end

  it "honors a configured readiness budget beyond the bootstrap limit for initial and replacement masters", startup_timeout: 0.5 do
    configure(reexec_timeout: 2, ready_delay: 0.7)
    first = start.fetch(:pid)
    configure(version: "two", reexec_timeout: 2, ready_delay: 0.7)
    Process.kill("USR2", Process.pid)
    second = wait_status { |row| row[:pid] != first && row[:workers].all? { |worker| worker[:version] == "two" } }
    expect(second[:reexec]).to include(state: "complete")
    expect(Integer(File.read(@pid_path))).to eq(second[:pid])
    expect { Process.kill(0, first) }.to raise_error(Errno::ESRCH)
  end

  it "kills and reaps an initial master that never configures", startup_timeout: 0.5 do
    configure(mode: "unconfigured")
    @thread = Thread.new { @launcher.run }
    pid = wait_status { |row| row[:pid] }.fetch(:pid)
    expect(@thread.join(3)).not_to be_nil
    expect(@thread.value).to eq(1)
    expect { Process.kill(0, pid) }.to raise_error(Errno::ESRCH)
    expect(File.exist?(@pid_path)).to be false
  end

  it "rejects configuration received after the absolute bootstrap deadline" do
    configure(reexec_timeout: 3, configuration_delay: 0.8)
    script = <<~RUBY
      launcher = Gritz::Supervisor::Launcher.new(
        command: [RbConfig.ruby, "-I", #{File.expand_path('../lib', __dir__).inspect},
                  #{File.expand_path('fixtures/launcher_master.rb', __dir__).inspect}, ARGV.fetch(0)],
        logger: Logger.new(File::NULL), status_io: IO.for_fd(4), startup_timeout: 0.5
      )
      exit launcher.run
    RUBY
    owner = Process.spawn(RbConfig.ruby, "-I", File.expand_path("../lib", __dir__), "-rgritz/core", "-rlogger",
                          "-e", script, @path, 4 => @writer, out: File::NULL, err: File::NULL)
    @thread = Thread.new { Process.waitpid2(owner).last }
    candidate = wait_status { |row| row[:pid] }.fetch(:pid)
    Process.kill("STOP", owner)
    sleep 1.2
    Process.kill("CONT", owner)
    expect(@thread.join(3)).not_to be_nil
    expect(@thread.value.exitstatus).to eq(1)
    expect { Process.kill(0, candidate) }.to raise_error(Errno::ESRCH)
    expect(File.exist?(@pid_path)).to be false
  ensure
    if @thread&.alive? && owner
      Process.kill("CONT", owner)
      Process.kill("QUIT", owner)
      @thread.join(3)
    end
  end

  it "reaps an unconfigured replacement and retains the serving master", startup_timeout: 0.5 do
    configure
    original = start.fetch(:pid)
    configure(version: "bad", mode: "unconfigured")
    Process.kill("USR2", Process.pid)
    candidate = wait_status { |row| row[:reexec]&.dig(:state) == "starting" }.fetch(:reexec).fetch(:pid)
    snapshot = wait_status { |row| row[:reexec]&.dig(:state) == "failed" && row[:masters].size == 1 }
    expect(snapshot[:pid]).to eq(original)
    expect(Integer(File.read(@pid_path))).to eq(original)
    expect { Process.kill(0, candidate) }.to raise_error(Errno::ESRCH)
    expect { Process.kill(0, original) }.not_to raise_error
  end

  it "keeps the original master when the configured readiness deadline expires", startup_timeout: 2 do
    configure
    original = start.fetch(:pid)
    configure(version: "late", reexec_timeout: 0.3, ready_delay: 0.5)
    Process.kill("USR2", Process.pid)
    snapshot = wait_status { |row| row[:reexec]&.dig(:state) == "failed" && row[:masters].size == 1 }
    expect(snapshot[:pid]).to eq(original)
    expect(snapshot[:reexec][:error]).to include("readiness timed out")
    expect(Integer(File.read(@pid_path))).to eq(original)
  end

  it "counts configuration loading against the absolute readiness budget", startup_timeout: 2 do
    configure
    original = start.fetch(:pid)
    configure(version: "late", reexec_timeout: 0.5, configuration_delay: 0.3, ready_delay: 0.3)
    Process.kill("USR2", Process.pid)
    snapshot = wait_status { |row| row[:reexec]&.dig(:state) == "failed" && row[:masters].size == 1 }
    expect(snapshot[:pid]).to eq(original)
    expect(snapshot[:reexec][:error]).to include("readiness timed out")
    expect(Integer(File.read(@pid_path))).to eq(original)
  end

  it "owns one inherited socket across fresh master generations" do
    configure(listener_strategy: "inherited_fd", bind: "127.0.0.1:0")
    first = start
    port = first[:workers].first[:port]
    expect(port).to be > 0
    configure(version: "two", listener_strategy: "inherited_fd", bind: "127.0.0.1:0")
    Process.kill("USR2", Process.pid)
    second = wait_status { |row| row[:pid] != first[:pid] && row[:workers].all? { |worker| worker[:version] == "two" } }
    expect(second[:workers].first[:port]).to eq(port)
    Process.kill("TERM", Process.pid)
    expect(@thread.join(3)).not_to be_nil
    expect(@thread.value).to eq(0)
    rebound = TCPServer.new("127.0.0.1", port)
    expect(rebound.addr[1]).to eq(port)
  ensure
    rebound&.close
  end

  %w[fail hang].each do |mode|
    it "retains the serving generation and PID when its replacement #{mode}s" do
      configure
      original = start.fetch(:pid)
      configure(version: "bad", mode:)
      Process.kill("USR2", Process.pid)
      wait_status { |row| row[:reexec]&.dig(:state) == "failed" }
      expect(Integer(File.read(@pid_path))).to eq(original)
      expect(@snapshot[:pid]).to eq(original)
      expect(@snapshot[:workers].first[:version]).to eq("one")
      expect { Process.kill(0, original) }.not_to raise_error
    end
  end

  it "returns a failing exit when the initial master cannot boot" do
    configure(mode: "fail")
    expect(@launcher.run).to eq(1)
    expect(File.exist?(@pid_path)).to be false
  end

  it "rejects an invalid listener strategy from a master before opening its listener" do
    configure(listener_strategy: "invalid")
    @thread = Thread.new { @launcher.run }
    expect(@thread.join(3)).not_to be_nil
    expect(@thread.value).to eq(1)
    expect(@log.string).to include("listener_strategy")
  end

  it "exposes an initially booted unhealthy worker and keeps HTTP readiness false" do
    configure(healthy: false)
    snapshot = start
    expect(snapshot[:pid]).to be_a(Integer)
    expect(snapshot[:ready_workers]).to eq(0)
    expect(snapshot[:workers].first).to include(state: "ready", healthy: false)
  end

  it "retains the healthy serving master when a replacement dependency never becomes ready" do
    configure
    original = start[:pid]
    configure(version: "unhealthy", healthy: false)
    Process.kill("USR2", Process.pid)
    snapshot = wait_status { |row| row[:reexec]&.dig(:state) == "failed" }
    expect(snapshot[:pid]).to eq(original)
    expect(snapshot[:workers].first[:version]).to eq("one")
  end

  it "accepts a new metric sequence after a retired PID is reused within one generation" do
    channel = instance_double(Gritz::Supervisor::StatusChannel)
    generation = described_class::Generation.new(pid: 123, channel: channel, token: 1, identities: {})
    metric = { type: "metrics", pid: 123, worker_pid: 456, seq: 1, delta: { rpc: [], rejected: 2 } }
    allow(channel).to receive(:read).and_return([metric], [{ type: "status", pid: 123, state: "running", workers: [] }], [metric])
    3.times { @launcher.send(:read_generation, generation) }
    metrics = @launcher.instance_variable_get(:@metrics).render
    expect(metrics).to include("gritz_rejected_total 4\n")
  end

  it "accepts a reused PID's new metric incarnation without an intervening removal snapshot" do
    channel = instance_double(Gritz::Supervisor::StatusChannel)
    generation = described_class::Generation.new(pid: 123, channel: channel, token: 1, identities: {})
    metric = { type: "metrics", pid: 123, worker_pid: 456, seq: 1, delta: { rpc: [], rejected: 2 } }
    allow(channel).to receive(:read).and_return([metric.merge(worker_started_at: 1.0)], [metric.merge(worker_started_at: 2.0)])
    2.times { @launcher.send(:read_generation, generation) }
    expect(@launcher.instance_variable_get(:@metrics).render).to include("gritz_rejected_total 4\n")
    expect(generation.identities.size).to eq(1)
  end

  it "returns failure when the active master's graceful shutdown fails" do
    configure(mode: "shutdown_failure")
    start
    Process.kill("TERM", Process.pid)
    expect(@thread.join(3)).not_to be_nil
    expect(@thread.value).to eq(1)
  end

  it "preserves permission failures when the target process still exists" do
    generation = described_class::Generation.new(pid: 123)
    allow(Process).to receive(:waitpid2).with(-123, Process::WNOHANG).and_return(nil)
    allow(Process).to receive(:kill).with("KILL", -123).and_raise(Errno::EPERM)
    expect { @launcher.send(:kill_group, generation) }.to raise_error(Errno::EPERM)
  end
end
