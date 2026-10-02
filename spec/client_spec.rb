# frozen_string_literal: true

require "spec_helper"

RSpec.describe Gritz::Client do
  let(:stub_class) do
    Class.new do
      def echo(*) = nil
      def names(*) = nil
      def greetings(*) = nil
      def chat(*) = nil
    end
  end
  let(:adapter) do
    Class.new do
      class << self
        attr_reader :connections

        def connect(**options)
          (@connections ||= []) << options
          Object.new
        end

        def invoke(method:, request:, options:, around:, **, &block)
          terminal = ->(context, &reply) { reply ? reply.call(context.request) : context.request }
          around.call(terminal, method: "/test.Service/#{method}", kind: :unary, request:, options:, &block)
        end
      end
    end
  end

  before do
    @previous_adapter = described_class.adapter
    @previous_middleware = described_class.middleware
    described_class.adapter = adapter
    described_class.middleware = Gritz::Middleware::Stack.new
    Gritz::ChannelRegistry.reset!
  end
  after do
    described_class.adapter = @previous_adapter
    described_class.middleware = @previous_middleware
    Gritz::ForkGuard.deactivate
    Gritz::ChannelRegistry.reset!
  end

  it "defines a complete lazy singleton API without constructing a channel or stub" do
    Gritz::ForkGuard.activate
    client = described_class.define(stub_class, target: "localhost:50051")
    expect(client).to be_a(Module)
    expect(%i[echo names greetings chat].all? { |method| client.respond_to?(method) }).to be true
    expect(adapter.connections).to be_nil
    expect { client.echo("request") }.to raise_error(Gritz::ForkGuard::Violation)
    expect(adapter.connections).to be_nil
  end

  it "shares one connection across definitions and guards calls even after a cache hit" do
    first = described_class.define(stub_class, target: "localhost:50051")
    second = described_class.define(stub_class, target: "localhost:50051")
    expect(first.echo("one")).to eq("one")
    expect(second.echo("two")).to eq("two")
    expect(adapter.connections.size).to eq(1)
    Gritz::ForkGuard.activate
    expect { second.echo("blocked") }.to raise_error(Gritz::ForkGuard::Violation)
    expect(adapter.connections.size).to eq(1)
  end

  it "uses middleware registered after defining the client" do
    middleware = Class.new do
      def initialize(app) = @app = app

      def call(context)
        context.request = "wrapped #{context.request}"
        @app.call(context)
      end
    end
    client = described_class.define(stub_class, target: "localhost:50051")
    described_class.middleware.use(middleware)
    expect(client.echo("request")).to eq("wrapped request")
  end

  it "serializes a validated service config without replacing other channel arguments" do
    config = { loadBalancingConfig: [{ round_robin: {} }] }
    client = described_class.define(stub_class, target: "localhost:50051", service_config: config,
                                                channel_args: { "grpc.keepalive_time_ms" => 1000 })
    config[:loadBalancingConfig].clear
    client.echo("request")
    expect(adapter.connections.first[:args]).to eq("grpc.keepalive_time_ms" => 1000,
                                                   "grpc.service_config" => '{"loadBalancingConfig":[{"round_robin":{}}]}')
  end

  it "rejects invalid definitions and expired calls before any connection is created" do
    expect { described_class.define(stub_class, target: "") }.to raise_error(ArgumentError, /target/)
    expect { described_class.define(stub_class, target: "host:1", service_config: []) }.to raise_error(ArgumentError, /service_config/)
    expect { described_class.define(stub_class, target: "host:1", deadline: -1) }.to raise_error(ArgumentError, /deadline/)
    expect { described_class.define(stub_class, target: "host:1", deadline: 0) }.to raise_error(ArgumentError, /deadline/)
    expect { described_class.define(stub_class, target: "host:1", safety_margin: Float::NAN) }.to raise_error(ArgumentError, /safety_margin/)
    client = described_class.define(stub_class, target: "host:1")
    expect { client.echo("request", deadline: Time.now - 1) }.to raise_error(Gritz::Errors::DeadlineExceeded)
    expect(adapter.connections).to be_nil
  end

  it "rejects non-JSON and cyclic service configs before serializing them" do
    invalid = [{ policy: Object.new }, { timeout: Float::INFINITY }]
    cyclic = {}
    cyclic[:again] = cyclic
    invalid << cyclic
    invalid.each do |service_config|
      expect { described_class.define(stub_class, target: "host:1", service_config:) }.to raise_error(ArgumentError, /service_config/)
    end
  end
end
