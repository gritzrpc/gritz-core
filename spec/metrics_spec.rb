# frozen_string_literal: true

require "spec_helper"
require "json"

RSpec.describe "RPC metrics" do
  def record(recorder, service: "test.Echo", method: "SayHello", code: 0, duration: 0.02, requests: 1, responses: 1)
    recorder.record_rpc(service: service, method: method, code: code, duration: duration, requests: requests, responses: responses)
  end

  it "collects concurrent RPC completions and detaches deltas without losing subsequent updates" do
    recorder = Gritz::Metrics::Recorder.new
    threads = 4.times.map { Thread.new { 25.times { record(recorder) } } }
    threads.each(&:value)
    recorder.observe_rejected(3)
    delta = recorder.take_delta
    expect(delta[:rpc].first).to include(count: 100, request_sum: 100, response_sum: 100)
    expect(delta[:rpc].first[:duration_buckets].sum).to eq(100)
    expect(delta[:rpc].first[:duration_sum]).to be_within(0.000001).of(2.0)
    expect(delta[:rejected]).to eq(3)
    expect(recorder.take_delta).to be_nil
    record(recorder, code: 5, requests: 2, responses: 0)
    recorder.observe_rejected(5)
    expect(recorder.take_delta).to include(rejected: 2, rpc: [include(code: 5, count: 1, request_sum: 2, response_sum: 0)])
    expect(delta[:rpc].first[:count]).to eq(100)
  end

  it "chunks large route sets under the byte budget while preserving every count" do
    recorder = Gritz::Metrics::Recorder.new
    12.times { |index| record(recorder, method: "Method#{index}") }
    recorder.observe_rejected(2)
    rows = []
    rejected = 0
    while (delta = recorder.take_delta(max_bytes: 700))
      expect(JSON.generate(delta).bytesize).to be <= 700
      rows.concat(delta[:rpc])
      rejected += delta[:rejected]
    end
    expect(rows.map { |row| row[:method] }.sort).to eq(12.times.map { |index| "Method#{index}" }.sort)
    expect(rows.sum { |row| row[:count] }).to eq(12)
    expect(rejected).to eq(2)
  end

  it "rejects invalid observations and an impossibly small packet budget without dropping data" do
    recorder = Gritz::Metrics::Recorder.new
    expect { record(recorder, duration: Float::NAN) }.to raise_error(ArgumentError)
    expect { record(recorder, code: 17) }.to raise_error(ArgumentError)
    expect { record(recorder, requests: -1) }.to raise_error(ArgumentError)
    expect { recorder.observe_rejected(-1) }.to raise_error(ArgumentError)
    recorder.observe_rejected(2)
    expect { recorder.observe_rejected(1) }.to raise_error(ArgumentError)
    record(recorder)
    expect { recorder.take_delta(max_bytes: 10) }.to raise_error(ArgumentError)
    expect(recorder.take_delta[:rpc].first[:count]).to eq(1)
  end

  it "deduplicates per worker, keeps totals after retirement, and exports cumulative histogram buckets" do
    recorder = Gritz::Metrics::Recorder.new
    record(recorder, duration: 0.004, requests: 0, responses: 1)
    record(recorder, duration: 0.02, requests: 2, responses: 3)
    recorder.observe_rejected(4)
    packet = { seq: 1, delta: recorder.take_delta }
    aggregator = Gritz::Metrics::Aggregator.new
    old = Object.new
    expect(aggregator.apply(old, packet)).to be(true)
    expect(aggregator.apply(old, packet)).to be(false)
    aggregator.forget(old)
    expect(aggregator.apply(Object.new, packet)).to be(true)
    aggregator.record_restart(reason: "worker_timeout")
    text = aggregator.render(workers: [{ pid: 123, index: 0, state: "ready", busy_threads: 2, capacity: 16, pss_bytes: 4096 }])
    labels = 'rpc_service="test.Echo",rpc_method="SayHello",rpc_grpc_status_code="0"'
    expect(text).to include("rpc_server_duration_seconds_count{#{labels}} 4\n")
    expect(text).to include("rpc_server_duration_seconds_bucket{#{labels},le=\"0.005\"} 2\n")
    expect(text).to include("rpc_server_duration_seconds_bucket{#{labels},le=\"+Inf\"} 4\n")
    expect(text).to include("rpc_server_requests_per_rpc_sum{#{labels}} 4\n")
    expect(text).to include("rpc_server_responses_per_rpc_sum{#{labels}} 8\n")
    expect(text).to include("gritz_rejected_total 8\n", "gritz_workers{state=\"ready\"} 1\n", "gritz_threadpool_busy 2\n",
                            "gritz_threadpool_capacity 16\n", "gritz_worker_pss_bytes{worker=\"0\",pid=\"123\"} 4096\n",
                            "gritz_worker_restarts_total{reason=\"worker_timeout\"} 1\n")
  end

  it "validates an entire packet before mutation and rejects sequence gaps" do
    recorder = Gritz::Metrics::Recorder.new
    record(recorder)
    valid = recorder.take_delta
    invalid = Marshal.load(Marshal.dump(valid))
    invalid[:rpc] << invalid[:rpc].first.merge(count: -1)
    aggregator = Gritz::Metrics::Aggregator.new
    worker = Object.new
    expect { aggregator.apply(worker, seq: 1, delta: invalid) }.to raise_error(Gritz::ConfigurationError)
    expect(aggregator.apply(worker, seq: 1, delta: valid)).to be(true)
    expect { aggregator.apply(worker, seq: 3, delta: valid) }.to raise_error(Gritz::ConfigurationError, /sequence/)
    expect { aggregator.apply(worker, seq: 2, delta: valid.merge(rejected: -1)) }.to raise_error(Gritz::ConfigurationError)
    expect(aggregator.apply(worker, seq: 2, delta: valid)).to be(true)
    expect(aggregator.render).to include('_count{rpc_service="test.Echo",rpc_method="SayHello",rpc_grpc_status_code="0"} 2')
  end

  it "escapes label values and exports empty and draining process gauges" do
    recorder = Gritz::Metrics::Recorder.new
    record(recorder, service: "test\"\\\nEcho")
    aggregator = Gritz::Metrics::Aggregator.new
    aggregator.apply(:worker, seq: 1, delta: recorder.take_delta)
    text = aggregator.render(workers: [{ pid: 1, index: 0, state: "draining", busy: 1, capacity: 4 }])
    expect(text).to include('rpc_service="test\\"\\\\\\nEcho"')
    expect(text).to include("gritz_workers{state=\"draining\"} 1\n", "gritz_threadpool_busy 1\n", "gritz_threadpool_capacity 4\n")
    expect(aggregator.render).to include("gritz_threadpool_busy 0\n", "gritz_threadpool_capacity 0\n")
  end

  it "accepts wire round trips, tuple identities, and launcher worker views" do
    recorder = Gritz::Metrics::Recorder.new
    record(recorder)
    packet = JSON.parse(JSON.generate(seq: 1, delta: recorder.take_delta), symbolize_names: true)
    aggregator = Gritz::Metrics::Aggregator.new
    expect(aggregator.apply([456, 123], packet)).to be(true)
    expect(aggregator.apply([456, 123], packet)).to be(false)
    worker = Struct.new(:pid, :index, :state, :stats).new(123, 0, "ready", { busy_threads: 1, capacity: 8 })
    expect(aggregator.render(workers: [worker])).to include("gritz_threadpool_busy 1\n", "gritz_threadpool_capacity 8\n")
    expect { aggregator.apply(:other, seq: 0, delta: {}) }.to raise_error(Gritz::ConfigurationError)
    malformed = Marshal.load(Marshal.dump(packet))
    malformed[:delta][:rpc].first[:duration_buckets][0] = 99
    expect { aggregator.apply(:other, malformed) }.to raise_error(Gritz::ConfigurationError, /histogram/)
  end
end
