# Gritz Core

Transport-independent controllers, routing, middleware, configuration, forked-worker supervision and network-free testing for Ruby gRPC applications. Requires CRuby 3.3 or later. This gem has no grpc dependency. Requiring the core does not load a transport; starting a server loads the selected adapter.

```ruby
require "gritz/core"
```

Use [gritz](https://github.com/gritzrpc/gritz) for the default framework and executable, or combine this gem with [gritz-native](https://github.com/gritzrpc/gritz-native) for the official grpc gem adapter. The Fiber adapter `gritz-async` is planned.

Controller tests can load `gritz/testing/rspec` or `gritz/testing/minitest` and run without a network or the grpc gem. See the [controller examples](https://github.com/gritzrpc/gritz#controllers) and [configuration guide](docs/guides/configuration.md).

Supervised servers support phased replacement, fresh-interpreter hot reexec, request/memory/lifetime recycling, Admin HTTP probes and process-wide Prometheus totals. The CLI keeps one lifecycle owner across master generations; application controllers and gRPC resources stay in serving processes.

`Gritz::Client.define` creates lazy, fork-safe client constants with deadline propagation, selected request headers and middleware around complete streams. See the [client guide](docs/guides/clients.md). Optional [gritz-otel](https://github.com/gritzrpc/gritz-otel) adds server/client spans and worker OTLP metrics after fork.

## Development

```sh
git clone https://github.com/gritzrpc/gritz-core.git
cd gritz-core
bundle install
COVERAGE=1 bundle exec rake
bundle exec rubocop
bundle exec rake build
```

Tests, lint and packaging run independently in this repository. See [CONTRIBUTING.md](CONTRIBUTING.md), [SECURITY.md](SECURITY.md) and the [release guide](docs/guides/releasing.md).

## License

[MIT](LICENSE.txt).
