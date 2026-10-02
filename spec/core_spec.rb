# frozen_string_literal: true

require "logger"
require "stringio"
require "open3"
require_relative "../lib/gritz/core"

RSpec.describe "application core" do
  let(:logger) { Logger.new(StringIO.new) }

  it "loads and eager loads without grpc or an optional test framework" do
    script = 'require "gritz/core"; Gritz::Core::LOADER.eager_load; ' \
             'abort "transport loaded" if defined?(GRPC); abort "test framework loaded" if defined?(RSpec)'
    output, status = Open3.capture2e(RbConfig.ruby, "-I", File.expand_path("../lib", __dir__), "-e", script)
    expect(status.success?).to be(true), output
  end

  it "preloads framework classes with the application without loading grpc or test frameworks" do
    script = 'require "gritz/core"; config = Gritz::Configuration.new; config.add_preloader {}; config.preload!; ' \
             'abort "framework remains lazy" if Gritz.autoload?(:Dispatcher) || Gritz::Worker.autoload?(:Runner) || Gritz::Metrics.autoload?(:Recorder); ' \
             'abort "transport loaded" if defined?(GRPC); abort "test framework loaded" if defined?(RSpec) || defined?(Minitest)'
    output, status = Open3.capture2e(RbConfig.ruby, "-I", File.expand_path("../lib", __dir__), "-e", script)
    expect(status.success?).to be(true), output
  end

  def service(name = "test.Echo", methods = { SayHello: [false, false] })
    stream_type = Struct.new(:type)
    rpc_type = Struct.new(:input, :output, :input_stream, :output_stream) do
      def client_streamer? = input_stream && !output_stream
      def server_streamer? = output_stream && !input_stream
      def bidi_streamer? = input_stream && output_stream
    end
    Class.new do
      define_singleton_method(:service_name) { name }
      define_singleton_method(:rpc_descs) do
        methods.transform_values do |(input_stream, output_stream)|
          rpc_type.new(input_stream ? stream_type.new(String) : String,
                       output_stream ? stream_type.new(String) : String, input_stream, output_stream)
        end
      end
    end
  end

  def controller(bound_service = service, &block)
    Class.new(Gritz::Controller) do
      bind bound_service
      class_eval(&block) if block
    end
  end

  def invoke(klass, action: "SayHello", messages: ["world"], **options)
    router = Gritz::Router.new(controllers: [klass], logger:)
    descriptor = router.routes.fetch("/#{klass.service_class.service_name}/#{action}")
    call = Gritz::Testing::InMemoryCall.new(method_descriptor: descriptor, messages:, **options)
    result = Gritz::Dispatcher.new(router:, logger:).call(call)
    [result, call]
  end

  it "defines all status codes without loading grpc" do
    expected = %i[ok cancelled unknown invalid_argument deadline_exceeded not_found already_exists permission_denied
                  resource_exhausted failed_precondition aborted out_of_range unimplemented internal unavailable data_loss unauthenticated]
    expected.each_with_index do |code, number|
      error = Gritz::Errors.for_code(code).new("problem", details: ["detail"], metadata: { "key" => "value" })
      expect([error.code, error.grpc_code, error.details, error.metadata]).to eq [code, number, ["detail"], { "key" => "value" }]
      expect(Gritz::Errors.for_code(number)).to eq(error.class)
    end
    expect { Gritz::Errors.for_code(:typo) }.to raise_error(ArgumentError)
    [-1, 17, nil, true].each { |code| expect { Gritz::Errors.for_code(code) }.to raise_error(ArgumentError) }
  end

  it "restores context and inherits it in new threads and fibers" do
    call = Gritz::Testing::InMemoryCall.new(method_descriptor: nil, messages: [], metadata: { "a" => "b" })
    ctx = Gritz::Context.new(call:, logger:)
    Gritz::Context.with(ctx) do
      expect(Fiber.new { Gritz::Context.current }.resume).to equal(ctx)
      expect(Thread.new { Gritz::Context.current }.value).to equal(ctx)
      expect { Gritz::Context.with(Gritz::Context.new(call:, logger:)) { raise "oops" } }.to raise_error("oops")
      expect(Gritz::Context.current).to equal(ctx)
    end
    expect(Gritz::Context.current).to be_nil
  end

  it "isolates sibling fibers and threads" do
    call = Gritz::Testing::InMemoryCall.new(method_descriptor: nil, messages: [])
    contexts = 2.times.map { Gritz::Context.new(call:, logger:) }
    fibers = contexts.map { |ctx|
      Fiber.new {
        Gritz::Context.with(ctx) {
          Fiber.yield
          Gritz::Context.current
        }
      }
    }
    fibers.each(&:resume)
    expect(fibers.map(&:resume)).to eq contexts
    expect(Thread.new { Gritz::Context.with(contexts[0]) { Gritz::Context.current } }.value).to equal(contexts[0])
    expect(Gritz::Context.current).to be_nil
  end

  it "checks deadlines and cancellation cooperatively" do
    call = Gritz::Testing::InMemoryCall.new(method_descriptor: nil, messages: [], deadline: Time.now - 1)
    ctx = Gritz::Context.new(call:, logger:)
    expect(ctx.remaining).to eq 0
    expect { ctx.check_deadline! }.to raise_error(Gritz::Errors::DeadlineExceeded)
    call.cancel!
    expect(ctx.cancelled?).to be true
    expect { ctx.check_cancelled! }.to raise_error(Gritz::Errors::Cancelled)
  end

  it "maps RPC names and preserves streaming types" do
    svc = service("test.Echo", UnaryRPC: [false, false], Upload: [true, false], Download: [false, true], Chat: [true, true])
    routes = Gritz::Router.new(controllers: [controller(svc)], logger:).routes.values
    expect(routes.map(&:kind)).to eq %i[unary client_streaming server_streaming bidi]
    expect(routes.first.action).to eq :unary_rpc
    expect(routes.first.input_type).to eq String
    expect(routes.first.output_type).to eq String
    expect(routes.map(&:input_type)).to eq [String] * 4
    expect(routes.map(&:output_type)).to eq [String] * 4
  end

  it "rejects duplicate service bindings and detects missing actions at boot" do
    svc = service
    expect { Gritz::Router.new(controllers: [controller(svc), controller(svc)], logger:) }.to raise_error(ArgumentError, /bound/)
    expect { Gritz::Router.new(controllers: [controller(svc)], strict: true, logger:) }.to raise_error(ArgumentError, /say_hello/)
    expect(logger).to receive(:warn).with(/say_hello/)
    Gritz::Router.new(controllers: [controller(svc)], logger:)
  end

  it "does not dispatch framework methods as application actions" do
    svc = service("test.Unimplemented", Context: [false, false], Class: [false, false])
    klass = controller(svc)
    expect { Gritz::Router.new(controllers: [klass], strict: true, logger:) }.to raise_error(ArgumentError, /context/)
    expect { invoke(klass, action: "Class") }.to raise_error(Gritz::Errors::Unimplemented)
  end

  it "dispatches unary requests with fresh controller instances" do
    klass = controller do
      def say_hello
        @count = (@count || 0) + 1
        "#{request.message}:#{@count}"
      end
    end
    expect(invoke(klass).first).to eq "world:1"
    expect(invoke(klass).first).to eq "world:1"
  end

  it "checks the deadline after an action and logs the final status" do
    current_time = Time.now
    allow(Time).to receive(:now) { current_time }
    klass = controller do
      define_method(:say_hello) do
        current_time += 2
        "late result"
      end
    end
    output = StringIO.new
    helper = Object.new.extend(Gritz::Testing::RpcHelper)
    expect {
      helper.rpc(:say_hello, "hello", controller: klass, deadline: current_time + 1, logger: Logger.new(output))
    }.to raise_error(Gritz::Errors::DeadlineExceeded)
    expect(output.string).to include('"code":"deadline_exceeded"')
    expect(Gritz::Context.current).to be_nil
  end

  it "checks cancellation after an action finishes" do
    klass = controller do
      def say_hello
        context.call.cancel!
        "cancelled result"
      end
    end
    expect { invoke(klass) }.to raise_error(Gritz::Errors::Cancelled)
  end

  it "rejects stream writes for unary and client-streaming methods" do
    unary = controller do
      def say_hello
        stream.write("unexpected response")
        "final response"
      end
    end
    expect { invoke(unary) }.to raise_error(Gritz::Errors::Internal) do |error|
      expect(error.metadata).to have_key("error-id")
    end
    uploading = controller(service("test.Stream", Upload: [true, false])) do
      def upload
        stream.write("unexpected response")
        "final response"
      end
    end
    expect { invoke(uploading, action: "Upload") }.to raise_error(Gritz::Errors::Internal)
  end

  it "dispatches all three streaming forms and keeps context through the entire stream" do
    svc = service("test.Stream", Upload: [true, false], Download: [false, true], Chat: [true, true])
    klass = controller(svc) do
      def upload = request.each_message.to_a.join(",")

      def download
        3.times do |index|
          raise "lost context" unless Gritz::Context.current.equal?(context)

          stream.write("#{request.message}:#{index}")
        end
      end

      def chat
        request.each_message { |message| stream.write(message.upcase) }
      end
    end
    expect(invoke(klass, action: "Upload", messages: %w[a b]).first).to eq "a,b"
    expect(invoke(klass, action: "Download").last.responses).to eq %w[world:0 world:1 world:2]
    expect(invoke(klass, action: "Chat", messages: %w[a b]).last.responses).to eq %w[A B]
    expect(Gritz::Context.current).to be_nil
  end

  it "runs inherited filters in order and supports only/except selectors" do
    events = []
    parent = controller do
      before_action { events << :before }
      around_action { |action|
        events << :around_before
        action.call
        events << :around_after
      }
      after_action { events << :after }
      def say_hello = "ok"
    end
    klass = Class.new(parent) do
      before_action(only: :say_hello) { events << :child }
      before_action(except: :say_hello) { events << :skipped }
    end
    expect(invoke(klass).first).to eq "ok"
    expect(events).to eq %i[around_before before child after around_after]
  end

  it "nests named around filters and keeps action results" do
    events = []
    klass = controller do
      around_action :first
      around_action :second
      define_method(:first) { |&action|
        events << :first
        action.call
        events << :first_end
      }
      define_method(:second) { |&action|
        events << :second
        action.call
        events << :second_end
      }
      def say_hello = "answer"
    end
    expect(invoke(klass).first).to eq "answer"
    expect(events).to eq %i[first second second_end first_end]
  end

  it "handles inherited rescue_from callbacks and rich fail! errors" do
    parent = controller do
      rescue_from ArgumentError, with: :recover
      def recover(error) = "recovered:#{error.message}"
      def say_hello = raise ArgumentError, "bad"
    end
    expect(invoke(Class.new(parent)).first).to eq "recovered:bad"
    failing = controller do
      def say_hello = fail!(:not_found, "missing", details: ["resource"], metadata: { "info" => "x" })
    end
    expect { invoke(failing) }.to raise_error(Gritz::Errors::NotFound) { |error| expect(error.details).to eq ["resource"] }
  end

  it "returns UNIMPLEMENTED for unknown routes and missing actions" do
    expect { invoke(controller) }.to raise_error(Gritz::Errors::Unimplemented)
    router = Gritz::Router.new(controllers: [], logger:)
    descriptor = Gritz::MethodDescriptor.new(service: "missing", name: "Nope", input_type: String, output_type: String)
    call = Gritz::Testing::InMemoryCall.new(method_descriptor: descriptor, messages: [])
    expect { Gritz::Dispatcher.new(router:, logger:).call(call) }.to raise_error(Gritz::Errors::Unimplemented)
  end

  it "hides internal error details and correlates the error with its log" do
    output = StringIO.new
    failing = controller do
      def say_hello = raise "database secret"
    end
    router = Gritz::Router.new(controllers: [failing])
    call = Gritz::Testing::InMemoryCall.new(method_descriptor: router.routes.values.first, messages: ["x"])
    expect { Gritz::Dispatcher.new(router:, logger: Logger.new(output)).call(call) }.to raise_error(Gritz::Errors::Internal) do |error|
      expect(error.message).not_to include "database secret"
      expect(error.metadata.fetch("error-id")).to match(/\A[0-9a-f-]+\z/)
      expect(output.string).to include(error.metadata.fetch("error-id"), "database secret")
    end
    expect(Gritz::Context.current).to be_nil
  end

  it "maps invalid response types before transport serialization" do
    unary = controller { def say_hello = Object.new }
    expect { invoke(unary) }.to raise_error(Gritz::Errors::Internal) do |error|
      expect(error.metadata).to have_key("error-id")
      expect(error.message).not_to include("Object")
    end
    streaming = controller(service("test.Stream", Download: [false, true])) do
      def download = stream.write(Object.new)
    end
    expect { invoke(streaming, action: "Download") }.to raise_error(Gritz::Errors::Internal)
  end

  it "propagates request IDs and logs one structured completion row" do
    output = StringIO.new
    klass = controller { def say_hello = context.request_id }
    router = Gritz::Router.new(controllers: [klass])
    call = Gritz::Testing::InMemoryCall.new(method_descriptor: router.routes.values.first, messages: ["x"], metadata: { "x-request-id" => "req-1" })
    expect(Gritz::Dispatcher.new(router:, logger: Logger.new(output)).call(call)).to eq "req-1"
    expect(call.initial_metadata).to eq("x-request-id" => "req-1")
    row = JSON.parse(output.string.lines.last.sub(/^.*? \{/, "{"))
    expect(row).to include("request_id" => "req-1", "service" => "test.Echo", "method" => "SayHello", "code" => "ok")
  end

  it "normalizes repeated request IDs and replaces invalid inbound IDs" do
    klass = controller { def say_hello = context.request_id }
    expect(invoke(klass, metadata: { "x-request-id" => %w[first second] }).first).to eq "first"
    ["", "x" * 129, "line\nbreak", 123].each do |invalid|
      expect(invoke(klass, metadata: { "x-request-id" => invalid }).first).to match(/\A[0-9a-f-]{36}\z/)
    end
  end

  it "edits the middleware stack and preserves nesting order" do
    events = []
    a = Class.new do
      define_method(:initialize) { |app, name:|
        @app = app
        @name = name
      }
      define_method(:call) { |ctx|
        events << @name
        @app.call(ctx)
      }
    end
    b = Class.new(a)
    c = Class.new(a)
    stack = Gritz::Middleware::Stack.new
    stack.use(a, name: :a)
    stack.insert_after(a, b, name: :b)
    stack.insert_before(b, c, name: :c)
    stack.swap(c, c, name: :swapped)
    stack.delete(b)
    expect(stack.build(lambda { |_ctx|
      events << :action
      "ok"
    }).call(nil)).to eq "ok"
    expect(events).to eq %i[a swapped action]
    expect { stack.insert_after(b, c) }.to raise_error(ArgumentError)
  end

  it "provides a network-free helper with metadata access and configurable middleware" do
    klass = controller do
      def say_hello
        context.call.trailing_metadata["result"] = "done"
        context.request_id || "without middleware"
      end
    end
    helper = Object.new.extend(Gritz::Testing::RpcHelper)
    expect(helper.rpc(:say_hello, "hello", controller: klass, metadata: { "x-request-id" => "req-2" })).to eq "req-2"
    expect(helper.last_rpc_call.trailing_metadata).to eq("result" => "done")
    expect(helper.rpc(:say_hello, "hello", controller: klass, middleware: false)).to eq "without middleware"
    expect { helper.rpc(:missing, "x", controller: klass) }.to raise_error(ArgumentError, /unknown RPC action/)
  end

  it "matches status errors in RSpec" do
    require_relative "../lib/gritz/testing/rspec"
    expect { raise Gritz::Errors::NotFound, "missing" }.to raise_rpc_error(:not_found)
    expect { "ok" }.not_to raise_rpc_error(:not_found)
  end

  it "provides the equivalent Minitest assertion" do
    require "minitest"
    checker = Class.new do
      include Minitest::Assertions
      include Gritz::Testing::Minitest

      attr_accessor :assertions

      def initialize = @assertions = 0
    end.new
    error = checker.assert_rpc_error(:not_found) { raise Gritz::Errors::NotFound, "missing" }
    expect(error.message).to eq "missing"
    expect(checker.assertions).to eq 2
  end
end
