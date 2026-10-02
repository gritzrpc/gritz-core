# frozen_string_literal: true

require "spec_helper"
require "tempfile"

RSpec.describe "Configuration and DSL" do
  it "keeps the release dependency selector out of runtime configuration" do
    config = Gritz::Configuration.load(env: { "GRITZ_RELEASE" => "1", "GRITZ_THREADS" => "2" })
    expect(config.threads).to eq(2)
  end
  def load_config(source, **options)
    Tempfile.create(["gritz", ".rb"]) do |file|
      file.write(source)
      file.flush
      Gritz::Configuration.load(path: file.path, **options)
    end
  end

  it "provides safe single-process defaults and independent mutable values" do
    config = Gritz::Configuration.new
    expect(config.workers).to eq(0)
    expect(config.threads).to eq(16)
    expect(config.bind).to eq("0.0.0.0:50051")
    expect(config.transport).to eq(:native)
    config.controllers << Class.new
    expect(Gritz::Configuration.new.controllers).to be_empty
    expect(config.validate!).to equal(config)
  end

  it "applies CLI overrides before environment before file before defaults" do
    config = load_config("workers 2\nthreads 4\nbind '127.0.0.1:1234'\n",
                         env: { "GRITZ_WORKERS" => "3", "GRITZ_THREADS" => "8" }, overrides: { workers: 0 })
    expect([config.workers, config.threads, config.bind]).to eq([0, 8, "127.0.0.1:1234"])
  end

  it "parses booleans and validates environment input" do
    config = load_config("", env: { "GRITZ_STRICT_ROUTES" => "true", "GRITZ_DRAIN_DELAY" => "0.5" })
    expect(config.strict_routes).to be true
    expect(config.drain_delay).to eq(0.5)
    %w[bad 1.2 -1].each do |value|
      expect { load_config("", env: { "GRITZ_WORKERS" => value }) }.to raise_error(Gritz::ConfigurationError)
    end
    expect { load_config("", env: { "GRITZ_STRICT_ROUTES" => "perhaps" }) }.to raise_error(Gritz::ConfigurationError)
  end

  it "rejects invalid types, nonfinite times, enum values and addresses" do
    [{ threads: 0 }, { workers: "2" }, { drain_delay: Float::INFINITY }, { fork_guard: :ignore },
     { bind: "host" }, { bind: "host:65536" }, { worker_recycle: { jitter: 1.1 } }].each do |values|
      config = Gritz::Configuration.new
      values.each { |name, value| config.public_send("#{name}=", value) }
      expect { config.validate! }.to raise_error(Gritz::ConfigurationError)
    end
  end

  it "rejects multi-worker ephemeral reuseport and unsupported FD passing" do
    expect { load_config("workers 2\nbind 'localhost:0'\n", env: {}) }.to raise_error(Gritz::ConfigurationError, /port 0/)
    expect { load_config("listener_strategy :inherited_fd\n", env: {}) }.to raise_error(Gritz::ConfigurationError, /inherited_fd/)
  end

  it "registers controllers, preload and lifecycle hooks without running them at load" do
    events = []
    config = Gritz::Configuration.new
    Gritz::DSL.new(config).instance_eval do
      preload_app! { events << :preload }
      before_fork { |index| events << index }
      register_controller String
      health_check(:database) { true }
    end
    expect(events).to be_empty
    config.preload!
    config.run_hooks(:before_fork, 7)
    expect(events).to eq([:preload, 7])
    expect(config.controllers).to eq([String])
    expect(config.health_checks[:database].call).to be true
  end

  it "maps security and connection limits to native grpc channel arguments" do
    config = Gritz::Configuration.new
    expect(config.server_args).to include("grpc.so_reuseport" => 1,
                                          "grpc.max_connection_age_ms" => 300_000,
                                          "grpc.max_receive_message_length" => 4 * 1024 * 1024,
                                          "grpc.max_send_message_length" => 4 * 1024 * 1024,
                                          "grpc.max_metadata_size" => 8192)
  end

  it "raises clear errors for unknown DSL settings and environment names" do
    expect { load_config("threds 1", env: {}) }.to raise_error(Gritz::ConfigurationError, /threds/)
    expect { load_config("", env: { "GRITZ_THREDS" => "1" }) }.to raise_error(Gritz::ConfigurationError, /GRITZ_THREDS/)
  end

  it "lets CLI values replace malformed environment values" do
    config = load_config("", env: { "GRITZ_WORKERS" => "bad" }, overrides: { workers: 0 })
    expect(config.workers).to eq(0)
  end

  it "shares runtime support validation with socket testing helpers" do
    config = Gritz::Configuration.new
    config.controllers = [Class.new]
    expect(config.validate_single_process!).to equal(config)
    config.transport = :async
    expect { config.validate_single_process! }.to raise_error(Gritz::ConfigurationError, /native/)
    config.transport = :native
    config.metrics_backend = :otlp
    expect { config.validate_single_process! }.to raise_error(Gritz::ConfigurationError, /metrics_backend/)
  end

  it "bounds grpc channel integers before native allocation" do
    config = Gritz::Configuration.new
    config.max_receive_message_size = 1 << 40
    expect { config.validate! }.to raise_error(Gritz::ConfigurationError, /max_receive_message_size/)
    config.max_receive_message_size = 1024
    config.keepalive_time = 1e20
    expect { config.validate! }.to raise_error(Gritz::ConfigurationError, /keepalive_time/)
  end

  it "accepts production health, recycling, log formatting and reexec settings" do
    source = <<~RUBY
      worker_recycle max_requests: 10, max_pss_mb: 128, max_lifetime: 30, jitter: 0.1
      health_check(:database) { true }
      log_format :logfmt
      pid_file '/tmp/gritz.pid'
    RUBY
    config = load_config(source, env: { "GRITZ_LOG_REDACT" => '["authorization"]' })
    config.controllers = [Class.new]
    config.workers = 2
    expect(config.validate_runtime!).to equal(config)
    expect(config.log_redact).to eq(["authorization"])
    expect(config.reexec_timeout).to eq(60.0)
    config.reexec_timeout = 0
    expect { config.validate! }.to raise_error(Gritz::ConfigurationError, /reexec_timeout/)
  end

  it "rejects operational settings that cannot be applied in this process mode" do
    config = Gritz::Configuration.new
    config.controllers = [Class.new]
    config.worker_recycle = { max_requests: 10 }
    expect { config.validate_runtime! }.to raise_error(Gritz::ConfigurationError, /workers > 0/)
    config.workers = 1
    config.bind = "127.0.0.1:0"
    expect { config.validate_runtime! }.to raise_error(Gritz::ConfigurationError, /fixed bind port/)
    config.bind = "127.0.0.1:50051"
    config.phased_restart_surge = 2
    expect { config.validate_runtime! }.to raise_error(Gritz::ConfigurationError, /phased_restart_surge/)
  end
end
