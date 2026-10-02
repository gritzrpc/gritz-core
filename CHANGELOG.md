# Changelog

## Unreleased

- Supervise forked workers with boot and heartbeat timeouts, automatic replacement, graceful shutdown, lifecycle hooks, dynamic worker counts and log reopening.
- Detect unsafe master-side gRPC initialization with ForkGuard and `gritz check`.
- Add `Gritz::Testing::Cluster` for process lifecycle integration tests.

## 0.1.0

Initial release.
