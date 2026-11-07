# Security

[Documentation](readme.md) · [Project overview](../README.md)

## Surface

Registry metadata and request-monitor statistics are rendered into HTML. The
application also exposes registry, telemetry and static-file endpoints, a public
read-only documentation and blog, and local mock service endpoints.

## Protections

Search workers load validated binary indexes and typed JSON metadata from a trusted
build artifact. Snapshot loading never evaluates scripts or indexes registry inputs.

Distribution targets are allowlisted and only configured object keys can be
signed. Redirects require a signed HTTPS URL and disable caching. Failed signing
returns a generic 503 without exposing credentials or SDK diagnostics. Release
metadata includes an executable checksum; no bucket listing or upload route is exposed.

Production Valkey connections require TLS and verify the CA and hostname,
including reconnects. LOCAL mode can use plain TCP only against localhost.

Content packages read validated Markdown snapshots, escape metadata and render
Markdown in safe mode. They expose only read routes and a CSS asset. The host
supplies trusted layouts. Local launchers bind mocks to loopback and keep host
secrets out of packages.

Template lookup is restricted to the dictionary loaded from the application's
`www` directory and treqmon's installed templates. jinja2-tcl never evaluates Tcl from templates. Contexts retain
JSON types, ordinary output is escaped, and chart JSON is escaped into HTML data
attributes before JavaScript parses it; it is never inserted as executable script.

Production secrets are supplied by user-managed SSM SecureString parameters.
tconfig encrypts them before packaging; Lambda decrypts through the private KMS
endpoint. Generated production files, local INI files and ZIP artifacts are ignored
by Git. No ACM private key is exported or stored in the repository.

## Pending

The existing request-monitor and debug routes have no authentication guard in
this repository. Apply the deployment's access controls before exposing them.
The mocks execute trusted local code and do not authenticate callers. They are
development services. The website HTTP API is public and has no authorizer.
