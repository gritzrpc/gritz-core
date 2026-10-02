# frozen_string_literal: true

require "spec_helper"
require "open3"
require "tmpdir"

RSpec.describe "Static Gruf configuration conversion" do
  def convert(source) = Gritz::Compat::Gruf::ConfigConverter.new.convert(source)

  def load_output(output)
    Dir.mktmpdir("gritz-converted-config") do |directory|
      path = File.join(directory, "gritz.rb")
      File.write(path, output)
      Gritz::Configuration.load(path:, env: {})
    end
  end

  it "converts literal binding, pool size, queue capacity and supported C-core arguments" do
    output = convert(<<~RUBY)
      Gruf.configure do |config|
        config.server_binding_url = "127.0.0.1:9001"
        config.rpc_server_options = {
          pool_size: 8,
          max_waiting_requests: 32,
          server_args: { "grpc.max_receive_message_length" => 8388608, "grpc.keepalive_time_ms" => 20000 }
        }
      end
    RUBY
    config = load_output(output)
    expect(config.bind).to eq("127.0.0.1:9001")
    expect(config.workers).to eq(0)
    expect(config.threads).to eq(8)
    expect(config.max_waiting_requests).to eq(32)
    expect(config.max_receive_message_size).to eq(8_388_608)
    expect(config.keepalive_time).to eq(20.0)
    expect(output).to include("register_controller", "Review")
  end

  it "converts explicitly enabled TLS file paths without reading the credential files" do
    output = convert(<<~RUBY)
      ::Gruf.configure do |c|
        c.use_ssl = true
        c.ssl_crt_file = "config/server.pem"
        c.ssl_key_file = "config/server.key"
      end
    RUBY
    expect(output).to include("tls({", '"config/server.pem"', '"config/server.key"')
  end

  it "handles empty configuration and explicit SSL disable without silently accepting TLS paths" do
    expect(load_output(convert("Gruf.configure { |c| }")).workers).to eq(0)
    expect(load_output(convert("Gruf.configure { |c| c.use_ssl = false }")).tls).to eq({})
    expect { convert('Gruf.configure { |c| c.ssl_key_file = "key.pem" }') }.to raise_error(Gritz::ConfigurationError, /ssl_key_file.*use_ssl/)
  end

  it "rejects unknown settings, unsupported server options and unconverted interceptors with actionable messages" do
    {
      'c.default_client_host = "localhost:9001"' => /default_client_host.*Client.define/,
      "c.rpc_server_options = { poll_period: 1 }" => /poll_period.*manual/,
      'c.rpc_server_options = { server_args: { "grpc.unknown_option" => 1 } }' => /grpc.unknown_option.*manual/,
      "c.interceptors.use(MyAuth)" => /interceptor.*manual/
    }.each do |statement, message|
      expect { convert("Gruf.configure do |c|\n#{statement}\nend") }.to raise_error(Gritz::ConfigurationError, message)
    end
  end

  it "rejects executable source, dynamic values, interpolation and splats without running them" do
    Dir.mktmpdir("gritz-static-conversion") do |directory|
      marker = File.join(directory, "executed")
      sources = [
        "File.write(#{marker.inspect}, 'executed'); Gruf.configure { |c| }",
        "Gruf.configure { |c| c.server_binding_url = File.write(#{marker.inspect}, 'executed') }",
        'Gruf.configure { |c| c.server_binding_url = "localhost:#{9001}" }', # rubocop:disable Lint/InterpolationCheck -- Untrusted Ruby source must retain its interpolation.
        "Gruf.configure { |c| c.rpc_server_options = { **other } }",
        "Gruf.configure { |c| if true; c.use_ssl = false; end }"
      ]
      sources.each { |source| expect { convert(source) }.to raise_error(Gritz::ConfigurationError, /manual|literal/) }
      expect(File.exist?(marker)).to be(false)
    end
  end

  it "rejects syntax errors, multiple blocks and duplicate assignments" do
    ["Gruf.configure do", "Gruf.configure { |c| }; Gruf.configure { |c| }",
     'Gruf.configure { |c| c.server_binding_url = "localhost:9001"; c.server_binding_url = "localhost:9002" }'].each do |source|
      expect { convert(source) }.to raise_error(Gritz::ConfigurationError)
    end
  end

  it "validates translated values before producing a file" do
    expect { convert("Gruf.configure { |c| c.rpc_server_options = { pool_size: 0 } }") }.to raise_error(Gritz::ConfigurationError, /threads/)
    expect { convert("Gruf.configure { |c| c.use_ssl = true }") }.to raise_error(Gritz::ConfigurationError, /ssl_crt_file.*ssl_key_file/)
  end

  it "prints the public CLI output and refuses to overwrite an existing destination" do
    Dir.mktmpdir("gritz-gruf-cli") do |directory|
      source = File.join(directory, "gruf.rb")
      destination = File.join(directory, "gritz.rb")
      File.write(source, 'Gruf.configure { |c| c.server_binding_url = "127.0.0.1:9001" }')
      command = [RbConfig.ruby, "-I", File.expand_path("../lib", __dir__), File.expand_path("../exe/gritz-migrate-gruf", __dir__), source]
      output, status = Open3.capture2e(*command)
      expect(status.success?).to be(true), output
      expect(load_output(output).bind).to eq("127.0.0.1:9001")
      File.write(destination, "existing")
      output, status = Open3.capture2e(*command, "--output", destination)
      expect(status.exitstatus).to eq(1)
      expect(output).to include("exists")
      expect(File.read(destination)).to eq("existing")
    end
  end
end
