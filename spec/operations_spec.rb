# frozen_string_literal: true

require "spec_helper"
require "logger"
require "stringio"
require "timeout"

RSpec.describe "Supervisor operations" do
  before do
    @config = Gritz::Configuration.new
    @config.workers = 2
    @config.bind = "127.0.0.1:50051"
    @master = Gritz::Supervisor::Master.new(@config, logger: Logger.new(StringIO.new))
    @pipes = []
    @created = []
    2.times { |index| add_worker(100 + index, index, state: "ready") }
    allow(@master).to receive(:spawn_worker) do |index|
      handle = add_worker(200 + @created.size, index, state: "booting")
      @created << handle
      handle
    end
    allow(Process).to receive(:kill)
  end

  after { @pipes.each { |io| io.close unless io.closed? } }

  def add_worker(pid, index, state:)
    reader, writer = IO.pipe
    @pipes.push(reader, writer)
    handle = Gritz::Supervisor::WorkerHandle.new(pid:, index:, status_io: reader)
    handle.update({ state:, healthy: true }, now: Process.clock_gettime(Process::CLOCK_MONOTONIC))
    @master.workers[pid] = handle
    handle
  end

  it "starts one replacement, waits for ready, then drains and reaps each old worker before continuing" do
    @master.send(:handle_signal, "USR1")
    @master.send(:advance_replacement)
    expect(@created.size).to eq(1)
    expect(@master.workers[100].term_at).to be_nil
    @created.first.update({ state: "ready", healthy: true }, now: Process.clock_gettime(Process::CLOCK_MONOTONIC))
    @master.send(:advance_replacement)
    expect(Process).to have_received(:kill).with("USR1", 100)
    expect(@master.workers[100].term_at).to be_a(Numeric)
    @master.send(:advance_replacement)
    expect(@created.size).to eq(1)
    @master.workers.delete(100)
    @master.send(:advance_replacement)
    expect(@created.size).to eq(2)
    expect(@master.status).to include(desired: 2, phased_restart: true)
  end

  it "keeps the original pool when a replacement fails boot" do
    @master.send(:handle_signal, "USR1")
    @master.send(:advance_replacement)
    @created.first.state = "failed"
    @master.send(:advance_replacement)
    expect(Process).to have_received(:kill).with("KILL", @created.first.pid)
    expect(@master.workers[100].term_at).to be_nil
    expect(@master.workers[101].term_at).to be_nil
    expect(@master.status[:phased_restart]).to be(false)
  end

  it "uses the same replacement path for request limits and refuses port zero" do
    @config.worker_recycle = { max_requests: 3, jitter: 0 }
    @master.workers[100].update({ state: "ready", healthy: true, requests_total: 3 }, now: Process.clock_gettime(Process::CLOCK_MONOTONIC))
    @master.send(:check_recycle)
    @master.send(:advance_replacement)
    expect(@created.size).to eq(1)
    @config.bind = "127.0.0.1:0"
    other = Gritz::Supervisor::Master.new(@config, logger: Logger.new(StringIO.new))
    expect(other).not_to receive(:spawn_worker)
    other.send(:handle_signal, "USR1")
    other.send(:advance_replacement)
  end

  it "reads every worker's readiness and metrics when the owner channel can accept the batches" do
    owner_reader, owner_writer = IO.pipe
    @pipes.push(owner_reader, owner_writer)
    owner = Gritz::Supervisor::StatusChannel.new(owner_writer)
    @master = Gritz::Supervisor::Master.new(@config, logger: Logger.new(StringIO.new), owner_channel: owner)
    recorder = Gritz::Metrics::Recorder.new
    2.times do |index|
      add_worker(100 + index, index, state: "booting")
      recorder.record_rpc(service: "test.Echo", method: "Echo", code: 0, duration: 0.01, requests: 1, responses: 1)
      @pipes.last.write("#{JSON.generate(type: 'metrics', seq: 1, delta: recorder.take_delta)}\n")
      @pipes.last.write("#{JSON.generate(state: 'ready', healthy: true)}\n")
    end
    @master.send(:read_statuses)
    expect(@master.workers.values.map(&:state)).to eq(%w[ready ready])
    packets = Gritz::Supervisor::StatusChannel.new(owner_reader).read
    expect(packets.map { |row| row[:worker_pid] }).to eq([100, 101])
    expect(@master.instance_variable_get(:@forwarded)).to be_empty
  end

  it "does not mistake owner backpressure for a failed worker heartbeat while retaining boot and shutdown deadlines" do
    @master.instance_variable_set(:@forwarded, [{ type: "metrics" }])
    timestamp = @master.workers.fetch(100).last_seen + @config.worker_timeout + @config.worker_boot_timeout
    allow(@master).to receive(:now).and_return(timestamp)
    @master.send(:check_timeouts)
    expect(Process).not_to have_received(:kill)
    @master.workers.fetch(101).state = "booting"
    @master.send(:check_timeouts)
    expect(Process).to have_received(:kill).with("KILL", 101)
    handle = @master.workers.fetch(100)
    handle.term_at = timestamp - @config.shutdown_timeout - 1
    handle.kill_at = timestamp - 1
    @master.send(:check_timeouts)
    expect(Process).to have_received(:kill).with("KILL", 100)
  end

  it "coalesces queued reexec requests while the owner is backpressured" do
    @master.instance_variable_set(:@owner_channel, double("blocked owner"))
    20.times { @master.send(:handle_signal, "USR2") }
    expect(@master.instance_variable_get(:@forwarded)).to eq([{ type: "reexec", pid: Process.pid }])
  end

  it "does not build master snapshots while an owner report remains blocked" do
    reader, writer = IO.pipe
    @pipes.push(reader, writer)
    loop { break if writer.write_nonblock("x" * 4096, exception: false) == :wait_writable }
    owner = Gritz::Supervisor::StatusChannel.new(writer)
    expect(owner.write(pid: 99)).to be(true)
    @master.instance_variable_set(:@owner_channel, owner)
    @master.instance_variable_set(:@reports, owner)
    @config.controllers = [Class.new]
    allow(@master).to receive(:require).with("gritz/native").and_return(true)
    allow(Gritz::ForkGuard).to receive(:activate).and_return(nil)
    allow(Process).to receive(:waitpid2).and_return(nil)
    allow(IO).to receive(:select) do
      owner.close
      @master.workers.clear
    end
    expect(@master).not_to receive(:status)
    expect(@master.run).to eq(1)
  end

  it "waits for writable owner IPC instead of spinning on worker pipes whose reads are paused" do
    reader, writer = IO.pipe
    @pipes.push(reader, writer)
    loop { break if writer.write_nonblock("x" * 4096, exception: false) == :wait_writable }
    @pipes[1].write("#{JSON.generate(state: 'ready')}\n")
    closed = false
    owner = double("blocked owner", io: writer, flush: false, write: false, close: nil)
    allow(owner).to receive(:closed?) { closed }
    @master.instance_variable_set(:@owner_channel, owner)
    @master.instance_variable_set(:@reports, owner)
    @master.instance_variable_set(:@forwarded, [{ type: "metrics" }])
    @config.controllers = [Class.new]
    allow(@master).to receive(:require).with("gritz/native").and_return(true)
    allow(Gritz::ForkGuard).to receive(:activate).and_return(nil)
    allow(Gritz::Supervisor::AdminServer).to receive(:new).and_return(double("admin", poll: nil, ios: [], close: nil))
    allow(Process).to receive(:waitpid2).and_return(nil)
    waited = []
    allow(IO).to receive(:select).and_wrap_original do |original, *arguments|
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = original.call(*arguments)
      waited << (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started)
      if waited.one?
        @master.instance_variable_get(:@forwarded).clear
        loop { break unless reader.read_nonblock(4096, exception: false).is_a?(String) }
      else
        closed = true
        @master.workers.clear
        @master.send(:begin_shutdown, immediate: true)
      end
      result
    end
    expect(@master.run).to eq(1)
    expect(waited.size).to eq(2)
    expect(waited).to all(be >= 0.04)
  end

  it "aggregates the final metrics left in a dead worker's pipe before closing it" do
    handle = @master.workers.fetch(100)
    recorder = Gritz::Metrics::Recorder.new
    recorder.record_rpc(service: "test.Echo", method: "Echo", code: 0, duration: 0.01, requests: 1, responses: 1)
    @pipes[1].write("#{JSON.generate(type: 'metrics', seq: 1, delta: recorder.take_delta)}\n")
    @pipes[1].close
    status = double("child status", exited?: true, success?: true)
    allow(Process).to receive(:waitpid2).with(100, Process::WNOHANG).and_return([100, status])
    allow(Process).to receive(:waitpid2).with(101, Process::WNOHANG).and_return(nil)
    @master.send(:reap_children)
    expect(handle.channel).to be_closed
    count = 'rpc_server_duration_seconds_count{rpc_service="test.Echo",rpc_method="Echo",rpc_grpc_status_code="0"} 1'
    expect(@master.instance_variable_get(:@metrics).render).to include(count)
  end

  it "reaps a dead worker without waiting for a descendant's inherited pipe writer to close" do
    handle = @master.workers.fetch(100)
    recorder = Gritz::Metrics::Recorder.new
    recorder.record_rpc(service: "test.Echo", method: "Echo", code: 0, duration: 0.01, requests: 1, responses: 1)
    @pipes[1].write("#{JSON.generate(type: 'metrics', seq: 1, delta: recorder.take_delta)}\n")
    status = double("child status", exited?: true, success?: true)
    allow(Process).to receive(:waitpid2).with(100, Process::WNOHANG).and_return([100, status])
    allow(Process).to receive(:waitpid2).with(101, Process::WNOHANG).and_return(nil)
    expect { Timeout.timeout(0.2) { @master.send(:reap_children) } }.not_to raise_error
    expect(handle.channel).to be_closed
    expect(@master.workers).not_to have_key(100)
    expect(@master.instance_variable_get(:@metrics).render).to include('rpc_grpc_status_code="0"} 1')
  end

  it "drains every final metric packet when the available pipe contents exceed one read budget" do
    stub_const("Gritz::Supervisor::StatusChannel::MAX_READ_BYTES", 64)
    recorder = Gritz::Metrics::Recorder.new
    3.times do |index|
      recorder.record_rpc(service: "test.Echo", method: "Echo", code: 0, duration: 0.01, requests: 1, responses: 1)
      @pipes[1].write("#{JSON.generate(type: 'metrics', seq: index + 1, delta: recorder.take_delta)}\n")
    end
    status = double("child status", exited?: true, success?: true)
    allow(Process).to receive(:waitpid2).with(100, Process::WNOHANG).and_return([100, status])
    allow(Process).to receive(:waitpid2).with(101, Process::WNOHANG).and_return(nil)
    expect { Timeout.timeout(0.2) { @master.send(:reap_children) } }.not_to raise_error
    expect(@master.instance_variable_get(:@metrics).render).to include('rpc_grpc_status_code="0"} 3')
  end

  it "fails startup when a worker is unexpectedly terminated by a signal before ready" do
    status = double("signaled child status", exited?: false, success?: false, termsig: Signal.list.fetch("SEGV"))
    @pipes[1].close
    allow(Process).to receive(:waitpid2).with(100, Process::WNOHANG).and_return([100, status])
    allow(Process).to receive(:waitpid2).with(101, Process::WNOHANG).and_return(nil)
    @master.send(:reap_children)
    expect(@master.instance_variable_get(:@exit_status)).to eq(1)
    expect(@master.instance_variable_get(:@shutdown_at)).not_to be_nil
  end

  it "counts an unplanned worker replacement without counting intentional retirements" do
    @master.instance_variable_set(:@ever_ready, true)
    child_status = double("killed status", exited?: false, termsig: Signal.list.fetch("KILL"), success?: false)
    allow(Process).to receive(:waitpid2).with(100, Process::WNOHANG).and_return([100, child_status])
    allow(Process).to receive(:waitpid2).with(101, Process::WNOHANG).and_return(nil)
    @master.send(:reap_children)
    expect(@master.instance_variable_get(:@metrics).render).to include('gritz_worker_restarts_total{reason="worker_exit"} 1')
  end

  it "reports an unexpected fatal signal during shutdown while preserving intentional deadline kills" do
    @master.instance_variable_set(:@ever_ready, true)
    @master.send(:begin_shutdown)
    @pipes[1].close
    status = double("signaled child status", exited?: false, success?: false, termsig: Signal.list.fetch("SEGV"))
    allow(Process).to receive(:waitpid2).with(100, Process::WNOHANG).and_return([100, status])
    allow(Process).to receive(:waitpid2).with(101, Process::WNOHANG).and_return(nil)
    @master.send(:reap_children)
    expect(@master.instance_variable_get(:@exit_status)).to eq(1)
    @master.instance_variable_set(:@exit_status, 0)
    @master.workers.fetch(101).state = "killed"
    @pipes[3].close
    allow(Process).to receive(:waitpid2).with(101, Process::WNOHANG).and_return([101, status])
    @master.send(:reap_children)
    expect(@master.instance_variable_get(:@exit_status)).to eq(0)
  end
end
