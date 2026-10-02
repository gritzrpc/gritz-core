# frozen_string_literal: true

require "spec_helper"
require "json"
require "logger"
require "open3"

RSpec.describe "Gruf controller compatibility" do
  def service(kind = :unary, action: :Echo)
    stream = Struct.new(:type)
    descriptor = Struct.new(:input, :output, :input_stream, :output_stream) do
      def client_streamer? = input_stream && !output_stream
      def server_streamer? = output_stream && !input_stream
      def bidi_streamer? = input_stream && output_stream
    end
    Class.new do
      define_singleton_method(:service_name) { "test.Compat" }
      define_singleton_method(:rpc_descs) do
        input = %i[client_streaming bidi].include?(kind)
        output = %i[server_streaming bidi].include?(kind)
        { action => descriptor.new(input ? stream.new(String) : String, output ? stream.new(String) : String, input, output) }
      end
    end
  end

  def build_controller(kind = :unary, action: :Echo, &block)
    bound = service(kind, action:)
    Class.new(Gritz::Compat::Gruf::Controller) do
      bind bound
      class_eval(&block)
    end
  end

  def rpc(klass, messages = "hello", **options)
    Object.new.extend(Gritz::Testing::RpcHelper).rpc(:echo, messages, controller: klass, **options)
  end

  it "provides an optional namespaced controller without loading Gruf or grpc" do
    expect(Gritz.const_defined?(:Compat)).to be(true)
    script = 'require "gritz/core"; require "gritz/compat/gruf"; abort if defined?(::Gruf) || defined?(::GRPC); ' \
             "abort unless Gritz::Compat::Gruf::Controller < Gritz::Controller"
    output, status = Open3.capture2e(RbConfig.ruby, "-I", File.expand_path("../lib", __dir__), "-e", script)
    expect(status.success?).to be(true), output
  end

  it "preserves message, metadata, active call and bound service access" do
    captured = nil
    klass = build_controller do
      define_method(:echo) do
        captured = request
        request.context[:actor] = "alice"
        "#{request.message}:#{request.context['actor']}"
      end
    end
    deadline = Time.now + 5
    expect(rpc(klass, metadata: { "authorization" => "fixture" }, peer: "test-peer", deadline:)).to eq("hello:alice")
    expect(klass.bound_service).to eq(klass.service_class)
    expect(captured.service).to eq(klass.service_class)
    expect(captured.method_key).to eq(:echo)
    expect(captured.method_name).to eq("test.compat.echo")
    expect(captured.metadata).to eq("authorization" => "fixture")
    expect(captured.active_call.metadata).to eq(captured.metadata)
    expect(captured.active_call.peer).to eq("test-peer")
    expect(captured.active_call.deadline).to eq(deadline)
    expect(captured.request_response?).to be(true)
    expect(captured.messages).to eq(["hello"])
  end

  it "preserves block-based client streaming and Enumerable bidi requests" do
    uploading = build_controller(:client_streaming) do
      def echo
        result = []
        request.messages { |message| result << message }
        result.join(":")
      end
    end
    expect(rpc(uploading, %w[one two])).to eq("one:two")
    bidi = build_controller(:bidi) do
      def echo
        return enum_for(:echo) unless block_given?

        request.messages.each { |message| yield message.upcase }
      end
    end
    expect(rpc(bidi, %w[one two])).to eq(%w[ONE TWO])
  end

  it "preserves the client-streaming message Proc and bidi message Enumerable" do
    uploading = build_controller(:client_streaming) do
      def echo
        raise TypeError, "expected the Gruf message Proc" unless request.message.is_a?(Proc)

        result = []
        request.message.call { |message| result << message }
        result.join(":")
      end
    end
    expect(rpc(uploading, %w[one two])).to eq("one:two")
    bidi = build_controller(:bidi) do
      def echo
        request.message.each { |message| stream.write(message.upcase) }
      end
    end
    expect(rpc(bidi, %w[one two])).to eq(%w[ONE TWO])
  end

  it "lets migrated interceptors wrap standard controllers without rereading or double-counting messages" do
    interceptor = Class.new(Gritz::Compat::Gruf::ServerInterceptor) do
      def call
        raise "wrong first request" unless request.message == "hello"

        yield
      end
    end
    bound = service
    captured = nil
    klass = Class.new(Gritz::Controller) do
      bind bound
      define_method(:echo) do
        captured = context
        request.message.upcase
      end
    end
    stack = Gritz::Middleware::Stack.default.use(Gritz::Compat::Gruf.interceptor(interceptor))
    output = StringIO.new
    expect(rpc(klass, middleware: stack, logger: Logger.new(output))).to eq("HELLO")
    expect(captured.requests_count).to eq(1)
    expect(output.string).to include('"bytes_in":5')
  end

  it "retains Gruf fail! positional application codes and JSON error trailers" do
    klass = build_controller do
      def echo
        fail!(:not_found, :missing_product, "not here", { "marker" => 42 })
      end
    end
    expect { rpc(klass) }.to raise_error(Gritz::Errors::NotFound) do |error|
      expect(error.message).to eq("not here")
      expect(error.metadata.fetch("marker")).to eq("42")
      expect(JSON.parse(error.metadata.fetch("error-internal-bin"))).to eq(
        "code" => "not_found", "app_code" => "missing_product", "message" => "not here", "field_errors" => [], "debug_info" => {}
      )
    end
  end

  it "maps Gruf bad_request and unauthorized status aliases" do
    { bad_request: Gritz::Errors::InvalidArgument, unauthorized: Gritz::Errors::PermissionDenied }.each do |code, expected|
      klass = build_controller { define_method(:echo) { fail!(code) } }
      expect { rpc(klass) }.to raise_error(expected)
    end
  end

  it "keeps field errors and explicitly supplied debug information" do
    klass = build_controller do
      def echo
        add_field_error(:name, :required, "name required")
        set_debug_info("application detail", "fixture line\nsecond line")
        fail!(:invalid_argument, :invalid_product, "invalid") if has_field_errors?
      end
    end
    expect { rpc(klass) }.to raise_error(Gritz::Errors::InvalidArgument) do |error|
      data = JSON.parse(error.metadata.fetch("error-internal-bin"))
      expect(data.fetch("field_errors")).to eq([{ "field_name" => "name", "error_code" => "required", "message" => "name required" }])
      expect(data.fetch("debug_info")).to eq("detail" => "application detail", "stack_trace" => ["fixture line", "second line"])
    end
  end

  it "shares one request and error through FIFO interceptor call/yield execution without rereading messages" do
    seen = []
    interceptor = Class.new(Gritz::Compat::Gruf::ServerInterceptor) do
      define_method(:call) do |&next_call|
        seen << [options.fetch(:name), request.message, request.object_id, error.object_id]
        request.context[:actor] = "alice"
        result = next_call.call
        seen << options.fetch(:name)
        result
      end
    end
    klass = build_controller do
      define_method(:echo) do
        seen << ["controller", request.message, request.object_id, error.object_id]
        "#{request.message}:#{request.context['actor']}"
      end
    end
    stack = Gritz::Middleware::Stack.default
    stack.use(Gritz::Compat::Gruf.interceptor(interceptor), name: "outer")
    stack.use(Gritz::Compat::Gruf.interceptor(interceptor), name: "inner")
    expect(rpc(klass, middleware: stack)).to eq("hello:alice")
    expect(seen.map { |entry| entry.is_a?(Array) ? entry.first : entry }).to eq(%w[outer inner controller inner outer])
    expect(seen.grep(Array).map { |entry| entry[2..] }.uniq.size).to eq(1)
  end

  it "preserves interceptor early authentication failure before controller dispatch" do
    interceptor = Class.new(Gritz::Compat::Gruf::ServerInterceptor) do
      def call
        fail!(:unauthenticated, :bad_token, "invalid token") unless request.metadata["token"] == options.fetch(:token)
        yield
      end
    end
    klass = build_controller { def echo = request.message }
    stack = Gritz::Middleware::Stack.default.use(Gritz::Compat::Gruf.interceptor(interceptor), token: "fixture-token")
    expect { rpc(klass, middleware: stack) }.to raise_error(Gritz::Errors::Unauthenticated)
    expect(rpc(klass, middleware: stack, metadata: { "token" => "fixture-token" })).to eq("hello")
  end

  it "does not expose compatibility framework helpers as RPC actions" do
    bound = service(action: :SetDebugInfo)
    klass = Class.new(Gritz::Compat::Gruf::Controller) { bind bound }
    expect { Gritz::Router.new(controllers: [klass], strict: true, logger: Logger.new(File::NULL)) }.to raise_error(ArgumentError, /set_debug_info/)
  end

  it "uses indifferent context keys with fetch, key? and merge!" do
    klass = build_controller do
      def echo
        request.context.merge!(actor: "alice")
        request.context[:id] = "42"
        "#{request.context.fetch('actor')}:#{request.context.fetch(:id)}:#{request.context.key?(:actor)}"
      end
    end
    expect(rpc(klass)).to eq("alice:42:true")
  end

  it "isolates mutated interceptor options across independent RPCs" do
    interceptor = Class.new(Gritz::Compat::Gruf::ServerInterceptor) do
      def call
        request.context[:seen] = options.fetch(:seen, false)
        options[:seen] = true
        yield
      end
    end
    klass = build_controller { def echo = request.context[:seen].to_s }
    stack = Gritz::Middleware::Stack.default.use(Gritz::Compat::Gruf.interceptor(interceptor))
    logger = Logger.new(File::NULL)
    router = Gritz::Router.new(controllers: [klass], logger:)
    dispatcher = Gritz::Dispatcher.new(router:, middleware: stack, logger:)
    results = 2.times.map do
      call = Gritz::Testing::InMemoryCall.new(method_descriptor: router.routes.values.first, messages: ["hello"])
      dispatcher.call(call)
    end
    expect(results).to eq(%w[false false])
  end

  it "enumerates streamed actions while interceptors and error logging remain active" do
    seen = []
    interceptor = Class.new(Gritz::Compat::Gruf::ServerInterceptor) do
      define_method(:call) do |&next_call|
        seen << :enter
        next_call.call
      ensure
        seen << :exit
      end
    end
    klass = build_controller(:server_streaming) do
      define_method(:echo) do |&reply|
        next enum_for(:echo) unless reply

        seen << :enumeration
        reply.call("first")
        fail!(:not_found, :later_failure, "after first")
      end
    end
    helper = Object.new.extend(Gritz::Testing::RpcHelper)
    stack = Gritz::Middleware::Stack.default.use(Gritz::Compat::Gruf.interceptor(interceptor))
    output = StringIO.new
    expect { helper.rpc(:echo, "hello", controller: klass, middleware: stack, logger: Logger.new(output)) }.to raise_error(Gritz::Errors::NotFound)
    expect(helper.last_rpc_call.responses).to eq(["first"])
    expect(seen).to eq(%i[enter enumeration exit])
    expect(output.string).to include('"code":"not_found"', '"bytes_out":5')
  end
end
