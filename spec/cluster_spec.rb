# frozen_string_literal: true

require "spec_helper"
require "rbconfig"

RSpec.describe Gritz::Testing::Cluster do
  def fake_cluster(script)
    described_class.new(config_path: __FILE__, command: [RbConfig.ruby, "-rjson", "-e", script])
  end

  let(:publisher) do
    <<~RUBY
      $stdout.sync = true
      io = IO.for_fd(3)
      io.sync = true
      workers = [{ pid: Process.pid, state: "ready" }]
      emit = ->(state) { io.puts(JSON.generate(state: state, workers: workers)) }
      Signal.trap("TERM") { puts "stopped"; exit }
      Signal.trap("TTIN") { workers << { pid: Process.pid + 1, state: "ready" }; emit.call("running") }
      emit.call("running")
      loop { sleep 0.1 }
    RUBY
  end

  it "starts a fresh process, reads snapshots and waits on a predicate" do
    cluster = fake_cluster(publisher).start
    expect(cluster.pid).not_to eq(Process.pid)
    expect(cluster.wait_until(workers: 1).workers.first).to include(state: "ready")
    expect(cluster.signal("TTIN").wait_until(workers: 2) { |status| status[:state] == "running" }).to equal(cluster)
    expect { cluster.start }.to raise_error(ArgumentError, /already started/)
    expect(cluster.stop).to equal(cluster)
    expect(cluster.wait).to be_success
    expect(cluster.logs).to include("stopped")
    expect(cluster.stop).to equal(cluster)
  ensure
    cluster&.stop
  end

  it "ensures block-scoped clusters are stopped" do
    expect do
      described_class.start(config_path: __FILE__, command: [RbConfig.ruby, "-rjson", "-e", publisher]) do |cluster|
        cluster.wait_until(state: nil) { |status| status[:state] == "running" }
        @pid = cluster.pid
        raise "example failed"
      end
    end.to raise_error("example failed")
    expect { Process.kill(0, @pid) }.to raise_error(Errno::ESRCH)
  end

  it "reports exited processes with their captured logs" do
    cluster = fake_cluster('warn "boot failed"; exit 7').start
    expect { cluster.wait_until }.to raise_error(RuntimeError, /exited.*boot failed/m)
    expect(cluster.wait.exitstatus).to eq(7)
  ensure
    cluster&.stop
  end

  it "waits for exit when the status pipe closes before the process does" do
    cluster = fake_cluster("IO.for_fd(3).close; sleep 0.1; exit 7").start
    expect { cluster.wait_until }.to raise_error(RuntimeError, /exited/)
    expect(cluster.wait.exitstatus).to eq(7)
  ensure
    cluster&.stop
  end

  it "bounds waits and kills its own process group if TERM is ignored" do
    cluster = fake_cluster("Signal.trap('TERM', 'IGNORE'); #{publisher.sub('Signal.trap("TERM") { puts "stopped"; exit }', '')}").start
    cluster.wait_until(workers: 1)
    expect { cluster.wait_until(workers: 2, timeout: 0.02) }.to raise_error(Timeout::Error, /did not reach/)
    expect { cluster.wait(timeout: 0.02) }.to raise_error(Timeout::Error, /did not exit/)
    cluster.stop(timeout: 0.02)
    expect(cluster.wait.termsig).to eq(Signal.list.fetch("KILL"))
  ensure
    cluster&.stop
  end

  it "handles use before starting and a failed spawn" do
    cluster = fake_cluster("")
    expect(cluster.status).to eq(state: "starting", workers: [])
    expect(cluster.logs).to eq("")
    expect(cluster.stop).to equal(cluster)
    expect { cluster.signal("TERM") }.to raise_error(ArgumentError, /not started/)
    expect { cluster.wait }.to raise_error(ArgumentError, /not started/)
    missing = described_class.new(config_path: __FILE__, command: ["/missing/gritz-test-command"])
    expect { missing.start }.to raise_error(Errno::ENOENT)
  end
end
