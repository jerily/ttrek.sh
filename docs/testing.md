# Testing

[Documentation](readme.md) · [Project overview](../README.md)

Run these commands from the website checkout after [setup](install.md).
The local stack test also needs a package built with
`ttrek run -script package-lambda -- --local-only`. Runtime and browser tests have
additional requirements described below.

```bash
ttrek run -script build-assets
npm test
ttrek run -script build-search
ttrek run tclsh9.1 "$PWD/tests/runtime-packages.tcl"
ttrek run tclsh9.1 "$PWD/tests/all.tcl"
ttrek run tclsh9.1 "$PWD/tests/config.test"
ttrek run tclsh9.1 "$PWD/tests/lambda-config.test"
ttrek run tclsh9.1 "$PWD/tests/telemetry-config.test"
ttrek run tclsh9.1 "$PWD/tests/telemetry.test"
ttrek run tclsh9.1 "$PWD/tests/lambda-valkey.tcl"
ttrek run tclsh9.1 "$PWD/tests/static-content.test"
ttrek run tclsh9.1 "$PWD/tests/installer.tcl"
ttrek run tclsh9.1 "$PWD/tests/upload-archives.test"
ttrek run tclsh9.1 "$PWD/tests/runtime-smoke.tcl"
ttrek run tclsh9.1 "$PWD/tests/local-stack.tcl"
```

`tests/runtime-packages.tcl` loads runtime and development packages without starting services.
`ttrek run tclsh9.1 tests/lambda-package.tcl dist/ttrek-sh.zip` checks a production
ZIP's release settings, bundled checksum manifest and exclusion of host config.
CodeBuild runs this after packaging and finalization, before deployment; it needs
neither decrypted credentials nor running services.
`tests/local-stack.tcl` runs the packaged site through all three installed mock
services on temporary ports. It checks documentation, HEAD/error behavior,
S3-backed asset changes, binary objects, signed release downloads and checksums,
Lambda payload 1.0 query/body handling, an unchanged archive, and shutdown cleanup.
Package before running this test. `TTREK_TEST_SITE_ZIP` and
`TTREK_TEST_S3_SEED` can select an isolated archive and seed directory. Package checks include `awss3`; release-handler tests cover target selection, signing
arguments, metadata, disabled downloads, invalid requests and signer failures.
Config tests cover manifest validation, paths, and exact environment/version
selection. The local stack test checks that uploaded metadata takes precedence
over seed hashes and the production section of the manifest.
The Tcl installer test uses mocked platform/download commands and disposable
homes to verify all supported targets, endpoints, Rosetta detection and overrides;
it does not download real distributions or modify the user's installation.
`tests/upload-archives.test` checks source mirror keys, build variants, duplicate
downloads, existing objects, partial failures and temporary-file cleanup with
stubbed AWS/curl commands. It also runs the shell launcher's dry-run mode against
a fixture registry, without contacting AWS or upstream servers.
The rendering tests validate all templates and exercise the real request handlers and
renderer with isolated service fixtures, including empty collections, dependency
conditions, version ordering and HTML/URL escaping. `tests/static-content.test`
exercises the package-mounted monitor, shared layout, configured master and asset
routes. Chart data and monitor routing internals are tested in treqmon itself. They do
not connect to Valkey, AWS or the telemetry database. CI runs them before packaging.

`npm test` checks deterministic asset fingerprints, byte preservation, manifest
updates, combined bundle startup and retained older files after rebuilds. `tests/static-content.test` also
checks manifest URLs in every shared layout, ETags, weak/list/wildcard conditions,
empty GET/HEAD `304` responses, missing/corrupt assets, cache policies, gzip
negotiation and canonical-host redirects.
The local stack checks these policies through the packaged Lambda and mock S3,
including changed objects and both API Gateway payload versions.

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
or AWS. LOCAL uses SQLite; PROD additionally requires `TTREK_TEST_POSTGRES`
connection settings for a disposable PostgreSQL database and `PGSSLROOTCERT`
pointing to its CA. PROD always verifies TLS.

`tests/lambda-config.test` checks production rejection of plaintext secrets, local
configuration isolation, local counter expiry, and release configuration during
Lambda startup, including manifest paths and signed download URLs. `tests/lambda-valkey.tcl` needs
`valkey-server` with TLS and runs two independent Lambda adapters against a disposable
cache, checking shared history, cross-process rate limiting, and trusted source-IP
handling. It uses synthetic credentials and makes no AWS calls. Infrastructure
validation: `cfn-lint devops/infra/*.yml devops/infra/40-api-gateway.json devops/sam-template.yaml`.

`tests/telemetry.test` exercises real SQLite persistence, all event types,
parameter binding, aggregate statistics, rollback and concurrent writers.
Set `TTREK_TEST_POSTGRES` to a Tcl dictionary of connection settings (for example
`database telemetry_test host localhost port 5432 user postgres password TEST_PASSWORD sslmode verify-full`)
to run the same tests against PostgreSQL. That test creates a unique schema and
removes it afterward. It also checks that PostgreSQL never loads SQLite and
runs four independent processes to exercise simultaneous cold starts and writes.
Use only a disposable test database. `tests/telemetry-config.test` verifies ENV
selection and required TLS without connecting to services.

Run `ttrek run tclsh9.1 tests/telemetry-maintenance.test` for lazy-loading and
private-event dispatch checks. With `TTREK_TEST_POSTGRES` pointing at a disposable
database, it also checks JSONL backup/restore, binary/text round trips, cursor
paging, truncated exports, sequence advancement, advisory locking, cleanup and
combined backup/vacuum execution. S3 upload is stubbed; no AWS resources are used.
No Docker or PostgreSQL command-line clients are required by the application.
