# Configuration

Use `gritz start -C config/gritz.rb`, `gritz routes`, or `gritz check`.
CLI `--workers`, `--threads`, `--bind` and `--strict-routes` override matching
environment variables, which override file settings, which override defaults.
The file may require application code and call `register_controller Controller`.
Empty route tables are permitted for inspection; servers require a controller.

Each scalar setting maps to `GRITZ_` plus its uppercase name. Integers and
decimals are parsed strictly; booleans accept `true`/`false` or `1`/`0`; enum
values use their lowercase symbol name. Unknown `GRITZ_*` names fail startup.
Configure callbacks, controller classes and middleware in Ruby.

| Setting | Default | Type / constraints |
| --- | --- | --- |
| `workers` | `0` | Nonnegative integer; 0 runs in the foreground without fork |
| `threads` | `16` | Positive integer |
| `max_waiting_requests` | `64` | Positive integer; ignored by grpc 1.83 |
| `transport` | `:native` | This release supports native |
| `listener_strategy` | `:reuseport` | This release supports reuseport |
| `bind` | `"0.0.0.0:50051"` | host:port; fixed port required with multiple workers |
| `fork_mode` | `:clean` | `:clean` or experimental `:grpc_fork_support` |
| `fork_guard` | `:raise` | `:raise`, `:warn`, or `:off` |
| `strict_routes` | `false` | Fail boot on missing application actions |
| `drain_delay` | `5.0` | Seconds before sending TERM to workers |
| `shutdown_timeout` | `25.0` | Positive seconds; grace after TERM before KILL |
| `worker_boot_timeout` | `60.0` | Positive seconds allowed for worker startup |
| `worker_timeout` | `30.0` | Positive seconds without a heartbeat before KILL |
| `status_interval` | `1.0` | Positive seconds between heartbeats |
| `max_connection_age` | `300.0` | Nonnegative seconds |
| `max_connection_age_grace` | `30.0` | Nonnegative seconds |
| `keepalive_time` | `60.0` | Nonnegative seconds |
| `keepalive_permit_without_calls` | `true` | Boolean |
| `max_receive_message_size` | `4194304` | Positive bytes |
| `max_send_message_size` | `4194304` | Positive bytes |
| `max_metadata_size` | `8192` | Positive bytes |
| `log_format` | `:json` | This release supports json |

Integers must fit a signed 32-bit native channel argument. Durations must be
finite, real and no larger than 2,147,483.647 seconds. Addresses support bracketed
IPv6. `GRITZ_WORKER_RECYCLE` and `GRITZ_TLS` parse JSON objects, but recycling,
TLS, health checks, Admin HTTP and metrics export are planned for v0.3.

```ruby
workers 4
bind "0.0.0.0:50051"
preload_app! { require_relative "../app/rpc" }
before_fork { |index| close_master_connections(index) }
on_worker_boot { |index| setup_worker(index) }
on_worker_shutdown { |index| cleanup_worker(index) }
```

The master runs preload callbacks once, then calls `Process.warmup` when
available. Each forked worker constructs its own gRPC server. Create channels,
credentials and servers in `on_worker_boot`, never in the master preload or
configuration file. `gritz check` loads the config and preload callbacks and
reports every intercepted constructor with its source location. It does not
start a listener or run worker hooks. On supervised startup, the default guard
rejects unsafe initialization before any worker is forked. `:warn` reports
violations, and `:off` disables enforcement; neither makes inherited gRPC state
safe. The check command still reports violations regardless of enforcement mode.

Linux supports load balancing between native reuseport listeners. macOS warns
for multiple workers; use `workers 0` for development and Linux for cluster tests.
Port 0 is allowed with a single worker, but TTIN cannot add a worker to that
ephemeral listener. Single-process worker hooks receive index 0.

| Signal to master | Behavior |
| --- | --- |
| `TERM`, `INT` | Publish draining state, wait drain_delay, TERM workers, KILL after shutdown_timeout, reap all workers |
| `QUIT` | KILL and reap all workers immediately |
| `TTIN` | Add one worker |
| `TTOU` | Gracefully remove one worker; retain at least one |
| `HUP` | Reopen master and worker log files |

Workers that exit or exceed boot/heartbeat deadlines are reaped and replaced.
An initial application boot error fails startup and cleans up all children.
Workers report heartbeat/status data on the main worker loop, so a blocked
process cannot appear healthy just because a separate heartbeat thread runs.

Experimental `fork_mode :grpc_fork_support` requires Linux, `workers > 0`, and
`GRPC_ENABLE_FORK_SUPPORT=1` in the process environment **before requiring grpc**.
Gritz calls the grpc gem's prefork/postfork callbacks around each fork. This mode
permits parent-side clients; parent-side servers and active bidirectional RPCs
are unsupported by grpc. Keep `:clean` for ordinary deployments.

`Testing::Server` remains a single-process socket helper. Use
`Gritz::Testing::Cluster.start(config_path: "config/gritz.rb")` on Linux to start
a supervisor in a fresh interpreter, wait with `wait_until(workers: 4)`, inspect
`workers`/`status`, send signals, and stop with guaranteed process cleanup.
