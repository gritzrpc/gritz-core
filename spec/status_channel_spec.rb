# frozen_string_literal: true

require "spec_helper"
require "open3"

RSpec.describe Gritz::Supervisor::StatusChannel do
  around do |example|
    @reader_io, @writer_io = IO.pipe
    @reader = described_class.new(@reader_io)
    @writer = described_class.new(@writer_io)
    example.run
  ensure
    @reader&.close
    @writer&.close
  end

  it "round-trips JSON status rows without waiting for an incomplete line" do
    expect(@reader.read).to eq([])
    expect(@writer.write(pid: 42, state: "ready")).to be(true)
    @writer_io.write('{"pid":43,')
    expect(@reader.read).to eq([{ pid: 42, state: "ready" }])
    @writer_io.write("\"state\":\"draining\"}\n")
    expect(@reader.read).to eq([{ pid: 43, state: "draining" }])
  end

  it "bounds allocation while polling idle status, signal and admin connections" do
    script = <<~'RUBY'
      require "gritz/core"
      require "logger"
      reader, writer = IO.pipe
      status = Gritz::Supervisor::StatusChannel.new(reader)
      signals = Gritz::Supervisor::SignalQueue.new(signals: [])
      admin = Gritz::Supervisor::AdminServer.new(bind: "127.0.0.1:0", status: -> { {} }, ready: -> { true },
        metrics: -> { "" }, logger: Logger.new(File::NULL))
      client = TCPSocket.new("127.0.0.1", admin.address.split(":").last)
      status.read; signals.drain; admin.poll
      GC.start
      GC.disable
      before = GC.stat(:malloc_increase_bytes)
      1000.times { status.read; signals.drain; admin.poll }
      allocated = GC.stat(:malloc_increase_bytes) - before
      GC.enable
      client.close; admin.close; signals.close; status.close; writer.close
      abort "idle polling allocated #{allocated} bytes" if allocated >= 512 * 1024
    RUBY
    output, result = Open3.capture2e(RbConfig.ruby, "-I", File.expand_path("../lib", __dir__), "-e", script)
    expect(result.success?).to be(true), output
  end

  it "rejects malformed or oversized records and resumes at the next line" do
    @writer_io.write("invalid\n[]\n")
    expect(@reader.read).to eq([])
    ((described_class::MAX_LINE_BYTES / 4096) + 1).times do
      @writer_io.write("x" * 4096)
      expect(@reader.read).to eq([])
    end
    @writer_io.write("\n{\"pid\":44}\n")
    expect(@reader.read).to eq([{ pid: 44 }])
    expect(@writer.write(message: "x" * described_class::MAX_LINE_BYTES)).to be(false)
    expect(@writer.write(value: Float::NAN)).to be(false)
    expect(@writer).not_to be_closed
  end

  it "reports clusters whose combined worker statuses exceed a single pipe write" do
    snapshot = { state: "running", workers: Array.new(32) { |index| { pid: index, state: "ready", stats: "x" * 256 } } }
    rows = []
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1
    loop do
      @writer.write(snapshot)
      rows.concat(@reader.read)
      break if rows.any?
      raise "snapshot stalled" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
    end
    expect(rows.first).to eq(snapshot)
  end

  it "returns promptly when the pipe is full and preserves partial writes" do
    while @writer_io.write_nonblock("x" * 512, exception: false).is_a?(Integer)
      # Fill the real pipe so the status writer has no available space.
    end
    expect(@writer.write(pid: 45)).to be(true)
    expect(@writer.flush).to be(false)
    expect(@writer.write(pid: 46)).to be(false)
    expect(@reader.read).to eq([])
    @writer_io.write("\n")
    expect(@reader.read).to eq([])
    expect(@writer.write(pid: 46)).to be(true)
    expect(@reader.read).to eq([{ pid: 45 }, { pid: 46 }])
  end

  it "builds a status only after pending output drains and never after close" do
    while @writer_io.write_nonblock("x" * 512, exception: false).is_a?(Integer)
      # Backpressure must prevent building a replacement for a pending record.
    end
    expect(@writer.write(pid: 53)).to be(true)
    built = 0
    build_status = lambda do
      built += 1
      { pid: 54 }
    end
    expect(@writer.write(&build_status)).to be(false)
    expect(built).to eq(0)

    expect(@reader.read).to eq([])
    @writer_io.write("\n")
    expect(@reader.read).to eq([])
    expect(@writer.write(&build_status)).to be(true)
    expect(built).to eq(1)
    expect(@reader.read).to eq([{ pid: 53 }, { pid: 54 }])

    @writer.close
    expect(@writer.write(&build_status)).to be(false)
    expect(built).to eq(1)
  end

  it "finishes an interrupted record before writing another record" do
    allow(@writer_io).to receive(:write_nonblock).and_wrap_original do |original, bytes, **options|
      original.call(bytes.byteslice(0, 3), **options)
    end
    expect(@writer.write(pid: 47)).to be(true)
    4.times { @writer.flush }
    expect(@reader.read).to eq([{ pid: 47 }])
    expect(@writer.flush).to be(true)
  end

  it "marks EOF or a broken pipe closed and makes close idempotent" do
    @writer.close
    expect(@reader.read).to eq([])
    expect(@reader).to be_closed
    expect(@reader.close).to be_nil
    expect(@writer.write(pid: 49)).to be(false)

    read_io, write_io = IO.pipe
    read_io.close
    broken = described_class.new(write_io)
    expect(broken.write(pid: 50)).to be(false)
    expect(broken).to be_closed
  ensure
    broken&.close
  end

  it "respects a caller's fixed byte budget while retaining incomplete JSON" do
    @writer.write(pid: 51)
    @writer.write(pid: 52)
    expect(@reader.read(max_bytes: 3)).to eq([])
    expect(@reader.read).to eq([{ pid: 51 }, { pid: 52 }])
    expect { @reader.read(max_bytes: 0) }.to raise_error(ArgumentError)
  end
end
