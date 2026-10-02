# Releasing

Each repository builds and publishes its own gem. Publish coordinated framework versions in this order:

1. [gritz-core](https://github.com/gritzrpc/gritz-core)
2. [gritz-native](https://github.com/gritzrpc/gritz-native)
3. [gritz](https://github.com/gritzrpc/gritz)

Wait for each Release workflow to succeed and its gem to become available on RubyGems before tagging the next repository. The release workflow sets `GRITZ_RELEASE=1`, so tests use published dependencies. Development and CI use the dependencies' Git repositories, allowing work before the initial publication.

## Trusted Publishing

Create a [pending trusted publisher](https://rubygems.org/profile/oidc/pending_trusted_publishers) for this gem on RubyGems:

| Field | Value |
| --- | --- |
| Gem name | `gritz-core` |
| Repository owner | `gritzrpc` |
| Repository name | `gritz-core` |
| Workflow filename | `release.yml` |
| Environment | `release` |

Leave reusable-workflow repository fields empty. No API key is needed. See the [RubyGems trusted publishing guide](https://guides.rubygems.org/trusted-publishing/).

## Publish a version

For a new gem, scaffold it with `bundle gem` and prepare all checks and release files, then stop before the first publication and ask the project owner to release it and configure Trusted Publishing. Initial CHANGELOG notes remain exactly `Initial release.`.

1. Update `lib/gritz/core/version.rb`. Component dependencies currently require the same version; update their gemspec requirements when changing the version policy.
2. Record user-visible changes in CHANGELOG. First release notes are exactly `Initial release.`. Documentation, tests, version bumps and tooling alone do not justify a release.
3. Run `bundle exec rake`, `bundle exec rubocop`, `bundle exec bundler-audit check --update` and `bundle exec rake build`. Commit, push main and wait for CI.
4. Configure Trusted Publishing for this repository and, if applicable, publish its dependencies first.
5. Push the matching tag from this repository:

```sh
git tag v0.1.0
git push origin v0.1.0
```

Replace `0.1.0` with the release version. `.github/workflows/release.yml` validates the tag, tests and builds this gem, publishes it through Trusted Publishing, then creates a GitHub Release from the matching CHANGELOG entry.

`rake release` is restricted to the tag-triggered workflow. It receives short-lived credentials from `rubygems/release-gem` and creates no commits or tags. If publication fails, inspect RubyGems before rerunning; published versions cannot be overwritten.
