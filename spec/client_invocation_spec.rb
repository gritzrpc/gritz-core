# frozen_string_literal: true

require "spec_helper"

RSpec.describe Gritz::Client::Invocation do
  let(:parent_class) do
    Struct.new(:deadline, :metadata, :request_id, :trace_context, :logger, :cancelled, keyword_init: true) do
      def cancelled? = cancelled
    end
  end
  let(:parent) do
    metadata = { "traceparent" => "parent-trace", "tracestate" => "vendor=state", "authorization" => "secret", "x-extra" => "private" }
    parent_class.new(deadline: Time.now + 10, metadata:,
                     request_id: "parent-id", trace_context: Object.new, cancelled: false)
  end
  let(:events) { [] }
  let(:observer) do
    observed = events
    Class.new do
      define_method(:initialize) do |app, label:|
        @app = app
        @label = label
        observed << [:build, label, Gritz::Context.current]
      end
      define_method(:call) do |context|
        observed << [:start, @label, context, Gritz::Context.current]
        @app.call(context)
      ensure
        observed << [:finish, @label]
      end
    end
  end

  before do
    @previous_middleware = Gritz::Client.middleware
    Gritz::Client.middleware = Gritz::Middleware::Stack.new
  end
  after { Gritz::Client.middleware = @previous_middleware }

  def invoke(invocation, kind: :unary, request: "request", &terminal)
    invocation.call(terminal, method: "/test.Service/Call", kind:, request:, options: invocation.options)
  end

  it "chooses the earliest absolute deadline at construction and reserves the parent's safety margin" do
    parent.deadline = Time.now + 0.5
    invocation = described_class.new(deadline: 20, safety_margin: 0.1, options: { deadline: Time.now + 5 }, parent:)
    expect(invocation.options[:deadline]).to eq(parent.deadline - 0.1)
    first = invocation.options[:deadline]
    invoke(invocation) { |context| expect(context.deadline).to eq(first) }
  end

  it "rejects expired, cancelled, invalid, and unsupported calls before transport work" do
    expect { described_class.new(options: { deadline: Time.now - 1 }) }.to raise_error(Gritz::Errors::DeadlineExceeded)
    expect { described_class.new(options: { deadline: 1 }) }.to raise_error(ArgumentError, /deadline/)
    expect { described_class.new(options: { return_op: true }) }.to raise_error(ArgumentError, /return_op/)
    expect { described_class.new(deadline: Float::INFINITY) }.to raise_error(ArgumentError, /deadline/)
    expect { described_class.new(deadline: Complex(1, 2)) }.to raise_error(ArgumentError, /deadline/)
    expect { described_class.new(safety_margin: -1) }.to raise_error(ArgumentError, /safety_margin/)
    parent.cancelled = true
    expect { described_class.new(parent:) }.to raise_error(Gritz::Errors::Cancelled)
  end

  it "copies selected headers and caller options without mutating either source" do
    metadata = { "authorization" => "explicit", "custom" => ["one"] }
    options = { metadata:, credentials: :credentials }
    invocation = described_class.new(options:, parent:)
    expect(invocation.options[:metadata]).to eq("authorization" => "explicit", "custom" => ["one"],
                                                "x-request-id" => "parent-id", "traceparent" => "parent-trace", "tracestate" => "vendor=state")
    invocation.options[:metadata]["custom"] << "two"
    expect(metadata).to eq("authorization" => "explicit", "custom" => ["one"])
    expect(options.keys).to eq(%i[metadata credentials])
    expect(invocation.options[:credentials]).to eq(:credentials)
  end

  it "captures mutable metadata strings and list values independently of their sources" do
    value = +"explicit"
    list_value = +"one"
    parent.metadata["traceparent"] = +"parent-trace"
    parent.request_id = +"parent-id"
    invocation = described_class.new(options: { metadata: { "custom" => value, "multi" => [list_value] } }, parent:)
    value.replace("changed")
    list_value.replace("changed")
    parent.metadata["traceparent"].replace("changed")
    parent.request_id.replace("changed")
    expect(invocation.options[:metadata].slice("custom", "multi", "traceparent", "x-request-id")).to eq(
      "custom" => "explicit", "multi" => ["one"], "traceparent" => "parent-trace", "x-request-id" => "parent-id"
    )
  end

  it "preserves explicit propagation headers and generates an ID without a server context" do
    invocation = described_class.new(parent:, options: { metadata: { "x-request-id" => "caller", "traceparent" => "caller-trace" } })
    expect(invocation.options[:metadata].slice("x-request-id", "traceparent")).to eq("x-request-id" => "caller", "traceparent" => "caller-trace")
    expect(described_class.new.options[:metadata]["x-request-id"]).to match(/\A[0-9a-f-]{36}\z/)
  end

  it "runs global and per-definition middleware around unary completion with a useful client context" do
    Gritz::Client.middleware.use(observer, label: :global)
    local = Gritz::Middleware::Stack.new.use(observer, label: :local)
    invocation = Gritz::Context.with(parent) { described_class.new(parent:, middleware: local) }
    result = invoke(invocation) do |context|
      expect(context.method.full_name).to eq("/test.Service/Call")
      expect(context.method.kind).to eq(:unary)
      expect(context.parent).to equal(parent)
      expect(context.trace_context).to equal(parent.trace_context)
      expect(context.metadata).to equal(context.options[:metadata])
      expect(context.store).to eq({})
      "reply"
    end
    expect(result).to eq("reply")
    expect(events.map { |event| event.first(2) }).to eq([%i[build local], %i[build global], %i[start global], %i[start local],
                                                         %i[finish local], %i[finish global]])
    expect(Gritz::Context.current).to be_nil
  end

  it "captures middleware and parent at facade invocation while starting a lazy stream at consumption" do
    Gritz::Client.middleware.use(observer, label: :captured)
    invocation = Gritz::Context.with(parent) { described_class.new(parent:) }
    Gritz::Client.middleware.use(observer, label: :later)
    stream = invoke(invocation, kind: :server_streaming) do |_context, &reply|
      expect(Gritz::Context.current).to equal(parent)
      reply.call("first")
      reply.call("second")
    end
    expect(stream).to be_an(Enumerator)
    expect(events.map(&:first)).to eq([:build])
    other_parent = Object.new
    Gritz::Context.with(other_parent) do
      expect(stream.map { |reply| [reply, Gritz::Context.current] }).to eq([["first", parent], ["second", parent]])
      expect(Gritz::Context.current).to equal(other_parent)
    end
    expect(events.map { |event| event.first(2) }).to eq([%i[build captured], %i[start captured], %i[finish captured]])
    expect(Gritz::Context.current).to be_nil
  end

  it "closes the entire middleware scope after a late streamed error" do
    Gritz::Client.middleware.use(observer, label: :stream)
    error = Gritz::Errors::Unavailable.new("late", remote: true)
    stream = invoke(described_class.new, kind: :bidi, request: ["request"]) do |_context, &reply|
      reply.call("first")
      raise error
    end
    replies = []
    expect { stream.each { |reply| replies << reply } }.to raise_error(error)
    expect(replies).to eq(["first"])
    expect(events.last).to eq(%i[finish stream])
  end

  it "unwinds middleware immediately when a consumer breaks a stream" do
    Gritz::Client.middleware.use(observer, label: :stream)
    stream = invoke(described_class.new, kind: :server_streaming) do |_context, &reply|
      reply.call("first")
      raise "must not continue"
    end
    stream.each { |reply| break if reply == "first" }
    expect(events.last).to eq(%i[finish stream])
  end

  it "checks the original deadline again when a delayed stream begins" do
    invocation = described_class.new(options: { deadline: Time.now + 0.01 })
    reached = false
    stream = invoke(invocation, kind: :server_streaming) { reached = true }
    allow(Time).to receive(:now).and_return(invocation.options[:deadline] + 1)
    expect { stream.to_a }.to raise_error(Gritz::Errors::DeadlineExceeded)
    expect(reached).to be false
  end

  it "lets middleware inject headers before the terminal and handles client-stream input lazily" do
    injector = Class.new do
      def initialize(app) = @app = app

      def call(context)
        context.metadata["traceparent"] = "child-span"
        @app.call(context)
      end
    end
    Gritz::Client.middleware.use(injector)
    produced = 0
    requests = Enumerator.new { |out|
      3.times {
        produced += 1
        out << produced
      }
    }
    invocation = described_class.new(parent:)
    expect(produced).to eq(0)
    expect(invoke(invocation, kind: :client_streaming, request: requests) do |context|
      expect(context.method.client_streaming?).to be true
      expect(context.metadata["traceparent"]).to eq("child-span")
      context.each_request.to_a
    end).to eq([1, 2, 3])
  end
end
