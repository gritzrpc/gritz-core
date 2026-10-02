# Security

Report suspected vulnerabilities privately through GitHub's [security advisories](https://github.com/gritzrpc/gritz-core/security/advisories/new), or email the maintainer at t.yudai92@gmail.com.

The server uses insecure gRPC transport. Deploy it on a trusted network or behind a TLS-terminating proxy. Applications must implement authentication and authorization in controllers or middleware. Internal exceptions are redacted in RPC responses; diagnostic logs should be access-controlled.

Inbound/outbound message and metadata size limits are enabled by default. Reflection and public administration endpoints are unavailable. CI checks dependencies with bundler-audit.
