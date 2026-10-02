# ADR 008: Guard constructors and report startup violations before forking

- Status: Accepted
- Date: 2026-10-02
- Tasks: T2-03, T2-09

The grpc gem implements some resource allocation in C-defined `.new` methods.
Prepending `initialize` alone does not reliably intercept these allocations.
Gritz prepends the singleton `.new` method, including keyword arguments and
blocks. Native adapter tests verify the actual C constructors and safe child
allocation in a fresh process.

The CLI records constructors while evaluating configuration so it can honor
the resulting worker count and guard mode. A clean supervised start rejects
recorded violations before forking and enforces the selected mode during
preload and `before_fork`. Single-process startup permits initialization.
`gritz check` records and reports all constructors, without forking or starting
a listener. Evaluating the config twice was rejected because hooks and application
initializers can have side effects.

Heartbeats run on the worker's main lifecycle loop. A separate heartbeat thread
could keep reporting readiness after the lifecycle loop stopped making progress.
The master uses its own monotonic receipt times for timeout decisions.
