# Contributing

Use CRuby 3.3 or later. Run `bundle install`, then `bundle exec rake`, `bundle exec rubocop` and `bundle exec rake build`. Run `COVERAGE=1 bundle exec rspec` to check line coverage. Socket-related changes must pass the real gRPC integration tests on Linux.

Write a failing behavior test before changing nontrivial logic. Keep commits focused. Public API comments use YARD's `@api public` tag. Avoid loading optional testing libraries in production.

Update CHANGELOG only for user-visible behavior. Documentation, internal tooling and tests alone do not justify a release. First release notes are exactly `Initial release.`. See [release instructions](docs/guides/releasing.md).

## Repositories

[gritz-core](https://github.com/gritzrpc/gritz-core) owns routing, controllers, middleware, configuration and network-free testing without a grpc dependency. [gritz-native](https://github.com/gritzrpc/gritz-native) owns the official grpc gem adapter and real-socket tests. [gritz](https://github.com/gritzrpc/gritz) combines them, provides the executable and contains the hello example.

Each repository has its own Gemfile, gemspec, tests, CI and release workflow. Keep application behavior in the core and wire-protocol details in the adapter.
