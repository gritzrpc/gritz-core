# Changelog

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
