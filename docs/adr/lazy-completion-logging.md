# Lazy completion logging

- Status: Accepted
- Date: 2026-10-03

## Context

The CPU profile of the dispatcher with a WARN-level Ruby Logger showed completion-log preparation on the hot path even though no INFO messages were emitted. `Logging#prepare` accounted for 391 inclusive samples out of 2,468 CPU samples in the retained before profile. JSON generation and string encoding also allocated objects whose output was discarded.

## Decision

Build completion fields inside `Logger#info`'s block. Ruby's Logger evaluates that block only when the INFO message will be emitted. Keep response handling, exception mapping, redaction, enabled JSON/logfmt output and metric accounting unchanged.

## Evidence

`bench/profile.rb` uses stackprof 0.2.28 with a 1ms CPU sampling interval. It warms up 10,000 calls, measures 200,000 in-memory unary dispatches three times, then collects a separate CPU profile. In the same Ruby 3.4.11 Linux ARM64 environment, median elapsed time fell from 2.574025s to 1.626221s (36.82%), and allocation count fell from 16,600,000 to 9,200,000 (44.58%; 83 to 46 objects per dispatch).

The before run loads the original logging middleware from the previous commit; the after run uses the changed middleware. Results are retained in [`profile-before.json`](../../bench/results/profile-before.json) and [`profile-after.json`](../../bench/results/profile-after.json). This measures suppressed-log dispatch overhead, not gRPC wire latency or enabled production logging. It does not establish the unary p50 performance target.

Run the profiler independently of other workloads:

```sh
BUNDLE_GEMFILE=bench/Gemfile bundle install
BUNDLE_GEMFILE=bench/Gemfile bundle exec ruby bench/profile.rb
```

## Alternatives and consequences

Removing completion logs or byte accounting would change observable behavior. Transport-specific serialization caches would add a second ownership contract. Neither is required to remove this measured waste. The change uses the standard Logger API and adds no runtime dependency. A regression test supplies a diagnostic object that raises if serialized, checks successful dispatch and metrics with INFO disabled, and checks mapped errors and failure metrics under the same log level.
