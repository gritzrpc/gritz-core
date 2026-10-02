# Clients

Load your generated service definitions and the native adapter, then define a client constant:

```ruby
require "gritz/native"
require_relative "hello_services_pb"

Greeter = Gritz::Client.define(
  Helloworld::Greeter::Stub,
  target: "localhost:50051",
  deadline: 2.0
)

reply = Greeter.say_hello(Helloworld::HelloRequest.new(name: "Ruby"))
```

Definition does not construct a stub or channel. The first call creates a connection; later calls with the same target, credentials and channel arguments share it in that process. After fork, the registry drops inherited references without closing native resources and the child creates its own connection. ForkGuard still checks every call, including cache hits: define clients in a supervised master, and call them in workers.

`credentials: :insecure` is the default. For TLS, provide `GRPC::Core::ChannelCredentials`, or a callable that builds credentials on the first connection. A callable keeps credential construction out of the master; it runs once per connection, rather than once per RPC. Channels retain those credentials until process exit.

## Deadlines and metadata

The effective deadline is the earliest of the configured default duration, an explicit per-call absolute `Time`, and the parent RPC deadline minus `safety_margin` (default `0.01` seconds). Expired or cancelled parents fail before connection creation. A lazy stream checks the deadline and cancellation again when consumed.

```ruby
Greeter.say_hello(request, deadline: Time.now + 0.5, metadata: { "tenant-id" => "example" })
```

Clients inherit `x-request-id`, `traceparent` and `tracestate`. They generate a request ID for standalone calls. Other incoming metadata, including credentials, is not copied; pass outgoing metadata explicitly. Call options and mutable metadata values are copied so callers can reuse their inputs.

## Streams and middleware

Generated method names and request types are retained. Client-streaming methods accept an enumerable. Server-streaming and bidirectional methods accept a response block or return a lazy Enumerator:

```ruby
Greeter.list_greetings(request).each { |reply| puts reply.message }
Greeter.record_names(requests.each)
Greeter.chat(requests.each) { |reply| puts reply.message }
```

Middleware surrounds the complete RPC, including response iteration. Ending enumeration early or raising in a consumer cancels the unfinished native operation. Input enumerables must cooperate with cancellation and finish their own blocking work; cancelling a native call cannot release an arbitrary Ruby `Queue#pop`. `return_op: true` is unsupported.

Register middleware globally with `Gritz::Client.middleware.use(MyMiddleware)`, or pass a `Gritz::Middleware::Stack` as `middleware:` to one definition. Middleware implements `initialize(app)` and `call(context)`, and calls `@app.call(context)`. The outgoing context exposes the method descriptor, request, metadata, deadline, parent server context, store and native operation. Input enumeration retains the parent context on native writer threads.

## Downstream errors

Non-OK statuses become `Gritz::Errors::*` exceptions with `grpc_code`, `metadata`, decoded `details` and `remote? == true`. Registered protobuf Any types are unpacked; unknown or malformed Any details remain available as Any objects. Invalid rich-status envelopes do not replace the wire status.

An unhandled remote error reaches the server's default exception mapper and becomes a safe `INTERNAL` response. Handle expected failures with controller `rescue_from`, or explicitly enable status passthrough:

```ruby
middleware do |stack|
  stack.swap Gritz::Middleware::ExceptionMapper,
             Gritz::Middleware::ExceptionMapper,
             passthrough_remote_errors: true
end
```

Passthrough exposes the downstream status, trailers and rich details to the caller.

## Native service configuration

`service_config:` accepts a JSON object and supplies it as the channel's `grpc.service_config`. Native C-core handles retries and load balancing; the framework does not add another retry loop. Configure retries for RPCs that are safe to repeat.

```ruby
Greeter = Gritz::Client.define(
  Helloworld::Greeter::Stub,
  target: "dns:///greeter:50051",
  channel_args: { "grpc.enable_retries" => 1 },
  service_config: {
    "loadBalancingConfig" => [{ "round_robin" => {} }],
    "methodConfig" => [{
      "name" => [{ "service" => "helloworld.Greeter", "method" => "SayHello" }],
      "retryPolicy" => { "maxAttempts" => 3, "initialBackoff" => "0.1s",
                         "maxBackoff" => "1s", "backoffMultiplier" => 2,
                         "retryableStatusCodes" => ["UNAVAILABLE"] }
    }]
  }
)
```

For server/client spans and worker OTLP metrics, add [gritz-otel](https://github.com/gritzrpc/gritz-otel). The native adapter remains a separate dependency of the application.
