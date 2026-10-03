# frozen_string_literal: true

require "rspec/core"
require "rspec/expectations"
require "grpc"
require "google/rpc/status_pb"
require "google/rpc/error_details_pb"
require "gritz/testing/server"

module Gritz
  module Testing
    # Shared wire tests using the official gRPC client as an independent oracle.
    # Include with adapter:, service:, stub:, request:, reply: for a four-method fixture.
    # Explicitly requiring this helper needs RSpec and grpc as test dependencies.
    # @api public
    module TransportContract
    end
  end
end

RSpec.shared_examples Gritz::Testing::TransportContract do |adapter:, service:, stub:, request:, reply:|
  let(:contract_request) { request }
  let(:contract_reply) { reply }

  define_method(:contract_controller) do |&block|
    response = reply
    Class.new(Gritz::Controller) do
      bind service
      define_method(:say_hello) { response.new(message: self.request.message.name) }
      define_method(:list_greetings) { 3.times { |i| stream.write(response.new(message: "#{self.request.message.name}:#{i}")) } }
      define_method(:record_names) { response.new(count: self.request.each_message.count) }
      define_method(:chat) { self.request.each_message { |msg| stream.write(response.new(message: msg.name)) } }
      class_eval(&block) if block
    end
  end

  define_method(:with_contract_server) do |controller = contract_controller, **settings, &block|
    config = Gritz::Configuration.new
    config.transport = adapter
    config.listener_strategy = adapter == :async ? :inherited_fd : :reuseport
    config.bind = "127.0.0.1:0"
    settings.each { |key, value| config.public_send("#{key}=", value) }
    Gritz::Testing::Server.start(config, controllers: [controller]) do |server|
      client = stub.new(server.address, :this_channel_is_insecure)
      block.call(client, server)
    end
  end

  it "preserves unary protobuf messages" do
    with_contract_server { |client| expect(client.say_hello(contract_request.new(name: "Ruby")).message).to eq("Ruby") }
  end

  it "preserves ordered server streaming messages" do
    with_contract_server do |client|
      expect(client.list_greetings(contract_request.new(name: "x")).map(&:message)).to eq(%w[x:0 x:1 x:2])
    end
  end

  it "reads client streams through half-close" do
    with_contract_server do |client|
      expect(client.record_names(%w[a b c].map { |name| contract_request.new(name:) }).count).to eq(3)
    end
  end

  it "replies to bidi input before the client half-closes" do
    gate = Queue.new
    requests = Enumerator.new do |output|
      output << contract_request.new(name: "first")
      gate.pop
      output << contract_request.new(name: "second")
    end
    with_contract_server do |client|
      responses = client.chat(requests, deadline: Time.now + 5)
      expect(responses.next.message).to eq("first")
      gate << true
      expect(responses.next.message).to eq("second")
      expect { responses.next }.to raise_error(StopIteration)
    end
  ensure
    gate << true
  end

  it "sends streaming output before the controller returns" do
    gate = Queue.new
    response = contract_reply
    controller = contract_controller do
      define_method(:list_greetings) do
        stream.write(response.new(message: "first"))
        gate.pop
        stream.write(response.new(message: "second"))
      end
    end
    with_contract_server(controller) do |client|
      responses = client.list_greetings(contract_request.new, deadline: Time.now + 5)
      expect(responses.next.message).to eq("first")
      gate << true
      expect(responses.next.message).to eq("second")
      expect { responses.next }.to raise_error(StopIteration)
    end
  ensure
    gate << true
  end

  it "passes binary metadata, deadline and peer, with separate headers and trailers" do
    observations = Queue.new
    response = contract_reply
    controller = contract_controller do
      define_method(:say_hello) do
        observations << [context.metadata, context.deadline, context.peer, context.peer_identity]
        context.call.send_initial_metadata("answer" => "initial", "reply-bin" => "\x00\xff".b, "repeat-bin" => ["a".b, "b".b])
        context.call.trailing_metadata["answer"] = "trailing"
        context.call.trailing_metadata["trailer-bin"] = "\x00\xfe".b
        response.new(message: context.request_id)
      end
    end
    with_contract_server(controller) do |client|
      deadline = Time.now + 5
      operation = client.say_hello(contract_request.new, return_op: true, deadline:,
                                                         metadata: { "x-request-id" => "req-1", "request-bin" => "\x00\xfd".b, "repeat" => %w[a b] })
      expect(operation.execute.message).to eq("req-1")
      expect(operation.metadata).to include("answer" => "initial", "reply-bin" => "\x00\xff".b, "x-request-id" => "req-1")
      expect(operation.trailing_metadata).to include("answer" => "trailing", "trailer-bin" => "\x00\xfe".b)
      expect(operation.metadata["repeat-bin"]).to eq(%w[a b])
      metadata, actual_deadline, peer, identity = observations.pop(timeout: 2)
      expect(metadata).to include("request-bin" => "\x00\xfd".b)
      expect(metadata["repeat"]).to eq(%w[a b])
      expect(actual_deadline).to be_within(0.1).of(deadline)
      expect(peer).to match(/ipv[46]:/)
      expect(identity).to be_nil
    end
  end

  it "encodes application status, metadata and rich protobuf details" do
    controller = contract_controller do
      def say_hello
        fail!(:not_found, "missing", metadata: { "lookup" => "failed" },
                                     details: [Google::Rpc::ResourceInfo.new(resource_type: "name", resource_name: "Ruby")])
      end
    end
    with_contract_server(controller) do |client|
      expect { client.say_hello(contract_request.new) }.to raise_error(GRPC::NotFound) do |error|
        expect(error.details).to eq("missing")
        expect(error.metadata).to include("lookup" => "failed")
        status = Google::Rpc::Status.decode(error.metadata.fetch("grpc-status-details-bin"))
        expect([status.code, status.message]).to eq([5, "missing"])
        expect(status.details.first.unpack(Google::Rpc::ResourceInfo).resource_name).to eq("Ruby")
      end
    end
  end

  it "preserves a non-OK status after streamed messages" do
    response = contract_reply
    controller = contract_controller do
      define_method(:list_greetings) do
        stream.write(response.new(message: "first"))
        fail!(:permission_denied, "revoked", metadata: { "reason" => "revoked" })
      end
    end
    with_contract_server(controller) do |client|
      responses = client.list_greetings(contract_request.new)
      expect(responses.next.message).to eq("first")
      expect { responses.next }.to raise_error(GRPC::PermissionDenied) do |error|
        expect(error.metadata).to include("reason" => "revoked")
      end
    end
  end

  it "hides internal exception messages" do
    controller = contract_controller { def say_hello = raise("database secret") }
    with_contract_server(controller) do |client|
      expect { client.say_hello(contract_request.new) }.to raise_error(GRPC::Internal) do |error|
        expect(error.details).not_to include("database secret")
        expect(error.metadata).to have_key("error-id")
      end
    end
  end

  it "rejects an unimplemented controller action" do
    controller = Class.new(Gritz::Controller) { bind service }
    with_contract_server(controller) do |client|
      expect { client.say_hello(contract_request.new) }.to raise_error(GRPC::Unimplemented)
    end
  end

  it "honors an active call deadline" do
    controller = contract_controller { def say_hello = sleep(1) }
    with_contract_server(controller) do |client|
      expect { client.say_hello(contract_request.new, deadline: Time.now + 0.05) }.to raise_error(GRPC::DeadlineExceeded)
    end
  end

  it "returns CANCELLED when the client cancels an active call" do
    entered = Queue.new
    gate = Queue.new
    controller = contract_controller do
      define_method(:say_hello) do
        entered << true
        gate.pop
        fail!(:cancelled, "cancelled")
      end
    end
    with_contract_server(controller) do |client|
      operation = client.say_hello(contract_request.new, return_op: true, deadline: Time.now + 5)
      caller = Thread.new do
        operation.execute
      rescue GRPC::BadStatus => e
        e
      end
      expect(entered.pop(timeout: 2)).to be(true)
      operation.cancel
      expect(caller.join(2)).not_to be_nil
      expect(caller.value).to be_a(GRPC::Cancelled)
      gate << true
    ensure
      gate << true
      operation&.cancel
      caller&.join(5)
    end
  end

  it "finishes an in-flight response during graceful shutdown" do
    entered = Queue.new
    gate = Queue.new
    response = contract_reply
    controller = contract_controller do
      define_method(:say_hello) do
        entered << true
        gate.pop
        response.new(message: "completed")
      end
    end
    with_contract_server(controller) do |client, server|
      caller = Thread.new { client.say_hello(contract_request.new, deadline: Time.now + 5) }
      expect(entered.pop(timeout: 2)).to be(true)
      stopper = Thread.new { server.transport.stop(deadline: Time.now + 3) }
      sleep 0.02 # Let shutdown enter its drain phase while the application remains blocked.
      gate << true
      expect(caller.value.message).to eq("completed")
      expect(stopper.join(4)).not_to be_nil
      expect(server.transport.stats).to include(inflight: 0)
    ensure
      gate << true
      caller&.join(5)
      stopper&.join(5)
    end
  end

  it "enforces the shutdown deadline on a blocked controller" do
    entered = Queue.new
    controller = contract_controller do
      define_method(:say_hello) do
        entered << true
        Queue.new.pop
      end
    end
    with_contract_server(controller) do |client, server|
      caller = Thread.new do
        client.say_hello(contract_request.new, deadline: Time.now + 5)
      rescue GRPC::BadStatus => e
        e
      end
      expect(entered.pop(timeout: 2)).to be(true)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      server.transport.stop(deadline: Time.now + 0.05)
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 1
      expect(caller.join(2)).not_to be_nil
      expect(caller.value).to be_a(GRPC::BadStatus)
      expect(server.transport.running?).to be(false)
    end
  end
end
