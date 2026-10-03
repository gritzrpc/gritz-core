# frozen_string_literal: true

require "spec_helper"
require "logger"
require "stringio"

RSpec.describe "RPC completion observability" do
  def controller(kind, &block)
    stream_type = Struct.new(:type)
    input_stream = %i[upload chat].include?(kind)
    output_stream = %i[download chat].include?(kind)
    rpc = Struct.new(:input, :output) do
      define_method(:client_streamer?) { input_stream && !output_stream }
      define_method(:server_streamer?) { output_stream && !input_stream }
      define_method(:bidi_streamer?) { input_stream && output_stream }
    end.new(input_stream ? stream_type.new(String) : String, output_stream ? stream_type.new(String) : String)
    service = Class.new do
      define_singleton_method(:service_name) { "test.Observability" }
      define_singleton_method(:rpc_descs) { { kind => rpc } }
    end
    Class.new(Gritz::Controller) do
      bind service
      class_eval(&block)
    end
  end

  def dispatch(klass, messages: ["abc"], log_level: Logger::INFO, **options)
    @output = StringIO.new
    @recorder = Gritz::Metrics::Recorder.new
    logger = Logger.new(@output, level: log_level)
    logger.formatter = ->(_severity, _time, _progname, message) { "#{message}\n" }
    router = Gritz::Router.new(controllers: [klass], logger: logger)
    call = Gritz::Testing::InMemoryCall.new(method_descriptor: router.routes.values.first, messages: messages,
                                            metadata: { "x-request-id" => "req-1" }, peer: "peer with spaces")
    result = Gritz::Dispatcher.new(router: router, logger: logger, metrics: @recorder, worker: 2, **options).call(call)
    [result, call]
  end

  it "counts an unread unary request once, the unary response, and its bytes in one JSON row" do
    klass = controller(:unary) { def unary = "xyz!" }
    expect(dispatch(klass).first).to eq("xyz!")
    row = JSON.parse(@output.string)
    expect(row).to include("worker" => 2, "bytes_in" => 3, "bytes_out" => 4, "request_id" => "req-1", "code" => "ok")
    expect(@recorder.take_delta[:rpc].first).to include(code: 0, count: 1, request_sum: 1, response_sum: 1)
  end

  it "counts cached unary reads once and all messages in each streaming shape" do
    unary = controller(:unary) { def unary = request.message + request.message }
    expect(dispatch(unary).first).to eq("abcabc")
    expect(@recorder.take_delta[:rpc].first).to include(request_sum: 1, response_sum: 1)
    uploading = controller(:upload) { def upload = request.each_message.to_a.join }
    expect(dispatch(uploading, messages: %w[a bc]).first).to eq("abc")
    expect(@recorder.take_delta[:rpc].first).to include(request_sum: 2, response_sum: 1)
    downloading = controller(:download) { def download = 2.times { stream.write(request.message) } }
    expect(dispatch(downloading).last.responses).to eq(%w[abc abc])
    expect(JSON.parse(@output.string)).to include("bytes_in" => 3, "bytes_out" => 6)
    expect(@recorder.take_delta[:rpc].first).to include(request_sum: 1, response_sum: 2)
    chatting = controller(:chat) { def chat = request.each_message { |message| stream.write(message.upcase) } }
    expect(dispatch(chatting, messages: %w[a bc]).last.responses).to eq(%w[A BC])
    expect(@recorder.take_delta[:rpc].first).to include(request_sum: 2, response_sum: 2)
  end

  it "records partial streaming replies and a non-OK status when an action fails" do
    klass = controller(:download) do
      def download
        stream.write("done")
        fail!(:not_found, "missing")
      end
    end
    expect { dispatch(klass) }.to raise_error(Gritz::Errors::NotFound)
    expect(JSON.parse(@output.string)).to include("code" => "not_found", "bytes_out" => 4)
    expect(@recorder.take_delta[:rpc].first).to include(code: 5, count: 1, request_sum: 1, response_sum: 1)
  end

  it "formats logfmt safely and masks fields before formatting" do
    klass = controller(:unary) { def unary = "ok" }
    dispatch(klass, log_format: :logfmt, log_redact: %w[peer request_id])
    expect(@output.string.lines.size).to eq(1)
    expect(@output.string).to include('peer="[FILTERED]"', 'request_id="[FILTERED]"', 'service="test.Observability"', 'code="ok"', "worker=2")
    expect(@output.string).not_to include("peer with spaces", "req-1")
  end

  it "skips completion formatting when INFO is disabled while preserving results and metrics" do
    klass = controller(:unary) do
      def unary
        # JSON must never inspect unused diagnostic objects at WARN level.
        diagnostic = Object.new
        def diagnostic.to_json(*) = raise("unused diagnostic was serialized")
        context.store[:gritz_error] = { diagnostic: diagnostic }
        "ok"
      end
    end
    expect(dispatch(klass, log_level: Logger::WARN).first).to eq("ok")
    expect(@output.string).to be_empty
    expect(@recorder.take_delta[:rpc].first).to include(code: 0, count: 1)
    failure = controller(:unary) { def unary = raise "private exception message" }
    expect { dispatch(failure, log_level: Logger::WARN) }.to raise_error(Gritz::Errors::Internal)
    expect(@output.string).to be_empty
    expect(@recorder.take_delta[:rpc].first).to include(code: 13, count: 1)
  end

  it "keeps internal error diagnostics in one masked completion row" do
    klass = controller(:unary) { def unary = raise "private exception message" }
    expect { dispatch(klass, log_redact: %w[message backtrace]) }.to raise_error(Gritz::Errors::Internal) do |error|
      expect(error.metadata).to have_key("error-id")
    end
    expect(@output.string.lines.size).to eq(1)
    row = JSON.parse(@output.string)
    expect(row).to include("code" => "internal", "error" => "RuntimeError", "message" => "[FILTERED]", "backtrace" => "[FILTERED]")
    expect(row.fetch("error_id")).to match(/\A[0-9a-f-]{36}\z/)
    expect(@output.string).not_to include("private exception message")
    expect(@recorder.take_delta[:rpc].first).to include(code: 13, response_sum: 0)
  end

  it "masks nested diagnostic fields and quotes complex logfmt values" do
    klass = controller(:unary) do
      def unary
        context.store[:gritz_error] = { metadata: [{ password: "nested secret", reason: "with spaces" }] }
        "ok"
      end
    end
    dispatch(klass, log_format: :logfmt, log_redact: ["password"])
    expect(@output.string).not_to include("nested secret")
    expect(@output.string).to include('metadata="[{\\"password\\":\\"[FILTERED]\\",\\"reason\\":\\"with spaces\\"}]"')
    expect(@output.string.lines.size).to eq(1)
  end

  it "preserves the mapped error when its diagnostic text contains binary bytes" do
    klass = controller(:unary) { def unary = raise "bad \xff".b }
    expect { dispatch(klass) }.to raise_error(Gritz::Errors::Internal)
    expect(JSON.parse(@output.string)).to include("code" => "internal", "message" => "bad �")
  end

  it "counts protobuf body bytes without writing payloads to completion logs" do
    require "google/protobuf/wrappers_pb"
    message = Google::Protobuf::StringValue.new(value: "sensitive")
    descriptor = Gritz::MethodDescriptor.new(service: "test.Bytes", name: "Unary", input_type: message.class, output_type: message.class)
    call = Gritz::Testing::InMemoryCall.new(method_descriptor: descriptor, messages: [message])
    context = Gritz::Context.new(call: call, logger: Logger.new(StringIO.new))
    context.record_received(message)
    context.record_sent(message)
    expect(context.bytes_in).to eq(message.class.encode(message).bytesize)
    expect(context.bytes_out).to eq(context.bytes_in)
  end
end
