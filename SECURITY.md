# Security

Report suspected vulnerabilities privately through [GitHub security advisories](https://github.com/gritzrpc/gritz-core/security/advisories/new), or email t.yudai92@gmail.com.

The default Native RPC listener is plaintext on `0.0.0.0:50051`. Configure `tls` for TLS; `client_ca` requires verified client certificates. Certificate/key/CA paths must name readable regular files. Client identity authorization remains application responsibility. Reflection is disabled unless explicitly enabled; Rails development enables it by default.

Admin HTTP defaults to `127.0.0.1:9090` and has no built-in authentication or TLS. Keep it on loopback or restrict it through network/proxy controls. Default message/metadata limits are enabled. Applications implement RPC authentication and authorization in controllers or middleware.

Internal RPC errors are redacted by default, but explicit error mappings and passthrough can reveal messages. Diagnostic logs contain error messages and backtraces; field redaction does not remove secrets embedded in arbitrary text. Restrict access to logs and status/metrics. CI audits dependencies with bundler-audit.

See the [security review](https://github.com/gritzrpc/gritz/blob/main/docs/security-review.md) and [support policy](https://github.com/gritzrpc/gritz/blob/main/docs/support-policy.md).
