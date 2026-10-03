# Changelog

## 0.9.1

- Add `gritz stats`, `stop` and `restart` to inspect the running server and signal its lifecycle owner without executing application configuration.
- Honor configured `reexec_timeout` values above 60 seconds for initial and replacement master readiness, including time already spent starting the generation.
- Check cooperative cancellation and pool-slot recovery for all four RPC forms in the shared transport contract.

## 0.9.0

- Start the 0.9 stabilization series with the documented public API and support policy.
- Reject directories and named pipes configured as TLS certificate, key or client CA files before allocating transport resources.

## 0.6.1

- Avoid formatting suppressed RPC completion logs, preserving responses, status mapping and metrics when INFO logging is disabled.

## 0.6.0

- Run Async workers through the same supervisor, CLI and real-server test helper as Native workers.
- Retain one inherited listener across forked workers and fresh master replacement, including ephemeral ports and recycling.
- Share adapter wire tests through `Gritz::Testing::TransportContract` without loading optional test dependencies in production.
- Preserve Async deadline errors through the standard exception middleware.

## 0.5.0

- Migrate Gruf controllers and server interceptors through `Gritz::Compat::Gruf`, with a configuration conversion tool.
- Configure optional gRPC Reflection through the `reflection` setting.
- Avoid unnecessary supervisor snapshot allocation when status consumers are paused.
- Publish worker metrics at `status_interval` to reduce supervisor overhead; retain retries and final shutdown totals.
- Eagerly load the transport-independent framework before application warmup so forked workers can share its memory.
- Send supervisor snapshots at `status_interval`, with immediate lifecycle and health changes, to reduce parent-process allocation.
- Reuse signal, status and admin read buffers to avoid allocating memory on every idle poll.

## 0.4.0

- Define lazy, fork-safe clients with process-local shared connections, per-call middleware, deadline propagation and selected request headers.
- Treat unhandled downstream errors as safe `INTERNAL` responses by default; allow explicit status passthrough.
- Support optional worker telemetry integrations with the remaining graceful shutdown budget.

## 0.3.0

- Replace workers one at a time with `USR1` and recycle them by request count, memory or lifetime.
- Reload application code with `USR2`; retain the serving master if replacement startup fails, and update the PID file after readiness.
- Keep admin probes and Prometheus totals available across worker and master replacement. Add application health checks and per-worker status.
- Emit one structured completion log per RPC with JSON or logfmt output and credential redaction.

## 0.2.0

- Supervise forked workers with boot and heartbeat timeouts, automatic replacement, graceful shutdown, lifecycle hooks, dynamic worker counts and log reopening.
- Detect unsafe master-side gRPC initialization with ForkGuard and `gritz check`.
- Add `Gritz::Testing::Cluster` for process lifecycle integration tests.

## 0.1.0

Initial release.
