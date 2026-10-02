# frozen_string_literal: true

require "spec_helper"

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

  it "rejects malformed or oversized records and resumes at the next line" do
    @writer_io.write("invalid\n[]\n")
    expect(@reader.read).to eq([])
    (described_class::MAX_LINE_BYTES / 4096 + 1).times do
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
    expect(@writer.write(pid: 45)).to be(false)
    expect(@reader.read).to eq([])
    @writer_io.write("\n")
    expect(@reader.read).to eq([])
    expect(@writer.write(pid: 46)).to be(true)
    expect(@reader.read).to eq([{ pid: 45 }, { pid: 46 }])
  end

  it "finishes an interrupted record before writing another record" do
    allow(@writer_io).to receive(:write_nonblock).and_wrap_original do |original, bytes, **options|
      original.call(bytes.byteslice(0, 3), **options)
    end
    expect(@writer.write(pid: 47)).to be(false)
    5.times { @writer.write(pid: 48) }
    expect(@reader.read.first).to eq(pid: 47)
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
end
