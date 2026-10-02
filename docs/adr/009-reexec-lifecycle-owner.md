# ADR 009: Keep one lifecycle owner across hot reexec

- Status: Accepted
- Date: 2026-10-02
- Tasks: T3-02, T3-05, T3-07

A container exits when its PID 1 exits. Replacing a master with a fork/exec child
and then exiting the original entrypoint would terminate the replacement too.
Repeated replacements must also avoid retaining a chain of retired parents.

The executable and cluster helper use a stable launcher that owns each master
generation as a direct child. The active master owns its worker pool and loads
application configuration in a fresh interpreter. The launcher promotes a new
generation only after its pool reports readiness, updates the PID file, then
drains the previous pool. A failed candidate leaves the existing generation
serving. USR1 uses the current preloaded image; USR2 reloads application code and
configuration.

The launcher retains the nongRPC Admin listener across handoffs and combines
active and retiring pool status and metrics. Its live check remains independent
of application health; readiness uses the active pool. It forwards signals and
reaps every owned generation, including failed candidates. Embedded supervisors
can retain their own Admin listener without a launcher.

Status writes accept complete records into a bounded pending buffer and flush
them without blocking the main loop. Workers retain metric deltas until accepted;
sequence numbers let the aggregator ignore repeated records. Graceful shutdown
flushes final counters and drains remaining pipe records before forgetting a
worker. A hard kill cannot recover counters that were never transmitted.
