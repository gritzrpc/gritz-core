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
| `workers` | `0` | Nonnegative integer; 0 uses one serving process |
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
| `log_format` | `:json` | `:json` or `:logfmt`, one completion row per RPC |
| `log_redact` | `[]` | Extra field/metadata names to mask, in addition to credential fields |
| `admin_bind` | `"127.0.0.1:9090"` | Admin HTTP host:port |
| `min_ready_workers` | `1` | Healthy ready workers required by `/readyz` |
| `metrics_backend` | `:pipe` | Worker deltas aggregated by the lifecycle owner |
| `worker_recycle` | `{}` | Request, RSS/PSS or lifetime limits; requires workers > 0 and a fixed port |
| `phased_restart_surge` | `1` | This release replaces one worker at a time |
| `pid_file` | `""` | Optional active master PID file; atomically replaced on USR2 |
| `reexec_timeout` | `60.0` | Positive seconds to wait for a replacement master |
| `tls` | `{}` | Readable `cert`, `key`, optional `client_ca` paths |

Integers must fit a signed 32-bit native channel argument. Durations must be
finite, real and no larger than 2,147,483.647 seconds. Addresses support bracketed
IPv6. `GRITZ_WORKER_RECYCLE` and `GRITZ_TLS` parse JSON objects;
`GRITZ_LOG_REDACT` parses a JSON array.

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

| Signal to launcher or master | Behavior |
| --- | --- |
| `TERM`, `INT` | Publish draining state, wait drain_delay, TERM workers, KILL after shutdown_timeout, reap all workers |
| `QUIT` | KILL and reap all workers immediately |
| `TTIN` | Add one worker |
| `TTOU` | Gracefully remove one worker; retain at least one |
| `HUP` | Reopen master and worker log files |
| `USR1` | Start a ready replacement before draining each old worker; requires workers > 0 and a fixed port |
| `USR2` | Start a fresh Ruby master; retain the previous generation if startup fails |

The executable and `Testing::Cluster` keep a stable launcher process. It owns
the HTTP listener and waits for every master generation. Signal that PID for
ordinary operations; `pid_file` contains the active master PID. An embedded
`CLI.new.run` or `Supervisor::Master` can run without the launcher, but USR2
requires `CLI.new(launch: true)` or the executable. USR1 uses the current
preloaded Ruby code and rereads TLS files. USR2 reloads code and configuration;
it cannot change the RPC bind, Admin bind or PID file path.
With `workers 0`, `USR1` is ignored with a warning; use `USR2` to reload the
serving process. Single-process TERM also observes `drain_delay` before stopping
RPC acceptance.

```ruby
admin_bind "127.0.0.1:9090"
health_check(:database) { database_available? }
worker_recycle max_requests: 50_000, max_pss_mb: 1024, max_lifetime: 3600, jitter: 0.1
log_format :logfmt
log_redact ["customer-token"]
tls cert: "/run/certs/server.pem", key: "/run/certs/server-key.pem", client_ca: "/run/certs/ca.pem"
```

`/livez` reports the owner loop's liveness. `/readyz` requires the configured
number of healthy, non-retiring workers and returns 503 during shutdown.
`/status` exposes process, workload and health diagnostics. `/metrics` exports
RPC duration/message histograms, rejection counts, worker/threadpool gauges,
PSS and restart reasons. Worker counters remain after retirement and USR2.
Graceful shutdown flushes final deltas; SIGKILL can lose observations not yet
sent. Health callbacks run on worker startup and each status interval; false
or an exception makes gRPC Health and HTTP readiness fail without killing a worker.

TLS credentials are created inside workers. `client_ca` enables required
client certificate verification; `context.peer_identity` exposes the peer PEM
certificate for application authorization. The default remains plaintext.
See the [Kubernetes guide](https://github.com/gritzrpc/gritz-native/blob/main/docs/guides/kubernetes.md)
for probes, draining and `tcp_migrate_req`.

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
