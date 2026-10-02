# frozen_string_literal: true

require "gritz/core"
require "json"
require "io/wait"

channel = Gritz::Supervisor::StatusChannel.new(IO.for_fd(3))
source = JSON.parse(File.read(ARGV.fetch(0)), symbolize_names: true)
exit 7 if source[:mode] == "fail"

channel.write(type: "configured", pid: Process.pid, workers: 1, bind: "127.0.0.1:50051",
              admin_bind: "127.0.0.1:0", min_ready_workers: 1, pid_file: source[:pid_file],
              reexec_timeout: 0.15, drain_delay: 0, shutdown_timeout: 0.1)
signals = Gritz::Supervisor::SignalQueue.new(signals: %w[TERM QUIT USR1 USR2 HUP TTIN TTOU])
state = source[:mode] == "hang" ? "booting" : "ready"
loop do
  signals.drain.each do |name|
    case name
    when "TERM", "QUIT" then exit(source[:mode] == "shutdown_failure" ? 7 : 0)
    when "USR2" then channel.write(type: "reexec", pid: Process.pid)
    end
  end
  channel.write(type: "status", pid: Process.pid, state: "running", desired: 1,
                workers: [{ pid: Process.pid, index: 0, state:, healthy: source.fetch(:healthy, true), version: source[:version], capacity: 1 }])
  signals.io.wait_readable(0.01)
end
