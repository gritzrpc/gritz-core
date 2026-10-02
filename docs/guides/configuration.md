# Configuration

Use `gritz start -C config/gritz.rb` or `gritz routes -C config/gritz.rb`.
CLI `--workers`, `--threads`, `--bind` and `--strict-routes` override matching
environment variables, which override file settings, which override defaults.
The file may require application code and call `register_controller Controller`.
Empty route tables are permitted for inspection; servers require a controller.

Each scalar setting below maps to `GRITZ_` plus its uppercase name.
Integers and decimals are parsed strictly; booleans accept `true`/`false` or
`1`/`0`; enum values use their lowercase symbol name. Unknown `GRITZ_*` names
fail startup to catch typos. `GRITZ_WORKER_RECYCLE` and `GRITZ_TLS` accept JSON
objects, but worker recycling and native TLS are unavailable. Configure callback
blocks, controller classes and middleware in Ruby.

| Setting | Default | Type / constraints |
| --- | --- | --- |
| `workers` | `0` | Server requires 0 |
| `threads` | `16` | Positive integer |
| `max_waiting_requests` | `64` | Positive integer; ignored by grpc 1.83 |
| `transport` | `:native` | Server requires native |
| `listener_strategy` | `:reuseport` | Server requires reuseport |
| `bind` | `"0.0.0.0:50051"` | host:port; port 0 allowed for single-process tests |
| `strict_routes` | `false` | Boolean; fail boot on missing application actions |
| `shutdown_timeout` | `25.0` | Positive seconds; native RPC shutdown grace |
| `max_connection_age` | `300.0` | Nonnegative seconds |
| `max_connection_age_grace` | `30.0` | Nonnegative seconds |
| `keepalive_time` | `60.0` | Nonnegative seconds |
| `keepalive_permit_without_calls` | `true` | Boolean |
| `max_receive_message_size` | `4194304` | Positive bytes |
| `max_send_message_size` | `4194304` | Positive bytes |
| `max_metadata_size` | `8192` | Positive bytes |
| `log_format` | `:json` | Server requires json |

Integers must fit a signed 32-bit native channel argument. Durations must be
finite, real and no larger than 2,147,483.647 seconds. Addresses support
bracketed IPv6.

The server runs in a single process. Worker recycling, experimental fork mode,
native TLS, health checks, alternate transports and metrics export are unavailable.

```ruby
preload_app! { require_relative "../app/rpc" }
on_worker_boot { |index| setup_worker(index) }
on_worker_shutdown { |index| cleanup_worker(index) }

middleware do |stack|
  stack.insert_after Gritz::Middleware::Logging, Authentication
end
```

Preload callbacks run before routing. Single-process worker hooks receive index
0. Route inspection does not run worker hooks.
`Testing::Server` applies the same feature validation and lifecycle as the CLI.
