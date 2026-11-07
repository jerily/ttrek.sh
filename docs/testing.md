# Testing

[Documentation](readme.md) · [Project overview](../README.md)

Run these commands from the website checkout after [setup](install.md).
The local stack test also needs a package built with
`ttrek run -script package -- --local-only`. Runtime and browser tests have
additional requirements described below.

```bash
ttrek run -script build-search
ttrek run tclsh9.1 "$PWD/tests/runtime-packages.tcl"
ttrek run tclsh9.1 "$PWD/tests/all.tcl"
ttrek run tclsh9.1 "$PWD/tests/config.test"
ttrek run tclsh9.1 "$PWD/tests/lambda-config.test"
ttrek run tclsh9.1 "$PWD/tests/lambda-valkey.tcl"
ttrek run tclsh9.1 "$PWD/tests/static-content.test"
ttrek run tclsh9.1 "$PWD/tests/installer.tcl"
ttrek run tclsh9.1 "$PWD/tests/runtime-smoke.tcl"
ttrek run tclsh9.1 "$PWD/tests/local-stack.tcl"
```

`tests/runtime-packages.tcl` loads runtime and development packages without starting services.
`tests/local-stack.tcl` runs the packaged site through all three installed mock
services on temporary ports. It checks documentation, HEAD/error behavior,
S3-backed asset changes, binary objects, signed release downloads and checksums,
Lambda payload 1.0 query/body handling, an unchanged archive, and shutdown cleanup.
Package before running this test. Package checks include `awss3`; release-handler tests cover target selection, signing
arguments, metadata, disabled downloads, invalid requests and signer failures.
Config tests cover manifest validation, paths, and exact environment/version
selection. The local stack test checks that uploaded metadata takes precedence
over seed hashes and the production section of the manifest.
The Tcl installer test uses mocked platform/download commands and disposable
homes to verify all supported targets, endpoints, Rosetta detection and overrides;
it does not download real distributions or modify the user's installation.
The rendering tests validate all templates and exercise the real request handlers and
renderer with isolated service fixtures, including empty collections, dependency
conditions, version ordering and HTML/URL escaping. `tests/static-content.test`
exercises the package-mounted monitor, shared layout, configured master and asset
routes. Chart data and monitor routing internals are tested in treqmon itself. They do
not connect to Valkey, AWS or the telemetry database. CI runs them before packaging.

Integration tests use Tcl 9.1 and the development dependency `trequests` 1.1.0
for HTTP, binary bodies and verified TLS. They need Linux `setsid` and OpenSSL
for isolated service processes and native checksums.

Optional browser regression checks require Python Playwright and Chromium in
your test environment. After packaging, run `TTREK_BROWSER_TESTS=1 ttrek run
tclsh9.1 "$PWD/tests/local-stack.tcl"`. `PLAYWRIGHT_PYTHON` can select that Python
interpreter. `tests/search_ui.py` is the only Python test. It covers keyboard and pointer selection, throttling,
out-of-order responses, escaping, network errors, mobile widths and search with
JavaScript disabled. Browser tooling is not needed to build or run the site.

The optional startup smoke test needs a local `valkey-server` executable
with TLS support:

```bash
VALKEY_SERVER=/path/to/valkey-server ttrek run tclsh9.1 "$PWD/tests/runtime-smoke.tcl"
```

It launches a disposable copy of the app with an isolated Valkey process, test
certificates and its own SQLite database under `build/`. It uses disposable ports,
checks Valkey-backed history/counters and reconnects, and never uses your config
or AWS. Run it with `ENV=LOCAL` and `ENV=PROD` to check both modes.

`tests/lambda-config.test` checks production rejection of plaintext secrets, local
configuration isolation, and local counter expiry. `tests/lambda-valkey.tcl` needs
`valkey-server` with TLS and runs two independent Lambda adapters against a disposable
cache, checking shared history, cross-process rate limiting, and trusted source-IP
handling. It uses synthetic credentials and makes no AWS calls. Infrastructure
validation: `cfn-lint devops/infra/*.yml devops/infra/40-api-gateway.json devops/sam-template.yaml`.
