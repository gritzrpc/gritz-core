# frozen_string_literal: true

require "spec_helper"
require "timeout"

RSpec.describe Gritz::ChannelRegistry do
  before { described_class.reset! }
  after { described_class.reset! }

  def fetch(**options, &block)
    described_class.fetch(target: "localhost:50051", credentials: :insecure, args: {}, **options, &block)
  end

  it "shares a connection only for equal process, adapter, target, credentials and arguments" do
    original = fetch { Object.new }
    expect(fetch { raise "duplicate factory" }).to equal(original)
    [{ target: "other:50051" }, { credentials: :tls }, { args: { "grpc.keepalive_time_ms" => 1000 } }, { pool: Object.new }].each do |options|
      expect(fetch(**options) { Object.new }).not_to equal(original)
    end
  end

  it "creates one connection when threads call the same target concurrently" do
    count = 0
    threads = Array.new(12) do
      Thread.new {
        fetch {
          count += 1
          Thread.pass
          Object.new
        }
      }
    end
    expect(threads.map(&:value).uniq.size).to eq(1)
    expect(count).to eq(1)
  end

  it "keeps cache identity stable after callers mutate argument strings and hashes" do
    args = { "grpc.primary_user_agent" => +"custom" }
    original = fetch(args:) { Object.new }
    args["grpc.primary_user_agent"] << " changed"
    args["other"] = 1
    expect(fetch(args: { "grpc.primary_user_agent" => "custom" }) { raise "identity changed" }).to equal(original)
    expect(fetch(args:) { Object.new }).not_to equal(original)
  end

  it "resets before an inherited locked mutex can be acquired after a PID change" do
    first = fetch { Object.new }
    lock = described_class.instance_variable_get(:@lock)
    lock.lock
    allow(Process).to receive(:pid).and_return(Process.pid + 1)
    second = Timeout.timeout(1) { fetch { Object.new } }
    expect(second).not_to equal(first)
  ensure
    lock&.unlock
  end

  it "clears the child's inherited connection and locked mutex before a fork block runs" do
    fetch { Object.new }
    lock = described_class.instance_variable_get(:@lock)
    lock.lock
    reader, writer = IO.pipe
    pid = Process.fork do
      reader.close
      created = false
      fetch {
        created = true
        Object.new
      }
      writer.write(created ? "new" : "inherited")
      writer.close
      exit! 0
    end
    writer.close
    expect(Timeout.timeout(2) { reader.read }).to eq("new")
    status = Process.waitpid2(pid).last
    pid = nil
    expect(status).to be_success
  ensure
    lock&.unlock
    reader&.close
    writer&.close unless writer&.closed?
    if pid
      begin
        Process.kill("KILL", pid)
        Process.wait(pid)
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      end
    end
  end
end
