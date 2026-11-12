# Testing

[Documentation](readme.md) · [Project overview](../README.md)

Run these commands from the website checkout after [setup](install.md).
The local stack test also needs a package built with
`ttrek run -script package-lambda -- --local-only`. Runtime and browser tests have
additional requirements described below.

```bash
ttrek run -script build-assets
npm test
ttrek run tclsh9.1 "$PWD/tests/runtime-packages.tcl"
ttrek run tclsh9.1 "$PWD/tests/all.tcl"
ttrek run tclsh9.1 "$PWD/tests/config.test"
ttrek run tclsh9.1 "$PWD/tests/lambda-config.test"
ttrek run tclsh9.1 "$PWD/tests/telemetry-config.test"
ttrek run tclsh9.1 "$PWD/tests/telemetry.test"
ttrek run tclsh9.1 "$PWD/tests/registry-metadata.test"
ttrek run tclsh9.1 "$PWD/tests/patch.test"
ttrek run tclsh9.1 "$PWD/tests/invoke-patch-local.test"
ttrek run tclsh9.1 "$PWD/tests/search-store.test"
ttrek run tclsh9.1 "$PWD/tests/lambda-valkey.tcl"
ttrek run tclsh9.1 "$PWD/tests/static-content.test"
ttrek run tclsh9.1 "$PWD/tests/content-images.test"
ttrek run tclsh9.1 "$PWD/tests/content-images-build.test"
ttrek run tclsh9.1 "$PWD/tests/installer.tcl"
ttrek run tclsh9.1 "$PWD/tests/upload-archives.test"
ttrek run tclsh9.1 "$PWD/tests/runtime-smoke.tcl"
ttrek run tclsh9.1 "$PWD/tests/local-stack.tcl"
```

`tests/runtime-packages.tcl` loads runtime and development packages without starting services.
`ttrek run tclsh9.1 tests/lambda-package.tcl dist/ttrek-sh.zip` checks a production
ZIP's release settings, bundled checksum manifest, image settings and bytes, and
exclusion of host config.
CodeBuild runs this after packaging and finalization, before deployment; it needs
neither decrypted credentials nor running services.
`tests/content-images-build.test` uses a fake S3 client to verify upload
deduplication across both collections, validation before uploads, build failure
on S3 errors, and production rendering without S3 listing or upload calls.
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
empty GET/HEAD `304` responses, missing assets, manifest-derived ETags, cache policies, gzip
negotiation and canonical-host redirects.
The local stack checks these policies through the packaged Lambda and mock S3,
including changed objects and both API Gateway payload versions.
It first verifies that search is unavailable in a fresh local runtime, then
explicitly invokes initialization and synchronization through the shared local
patch helper. Local startup performs neither task automatically.

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

`tests/registry-metadata.test` uses the same backend selection. It covers existing
schema upgrades, per-version metadata, imports from multiple registries, repeated
and concurrent imports, invalid recipes, and preservation of IDs and telemetry.

`tests/patch.test` also uses that backend selection. It verifies that repeated
`task_initdb_website` calls preserve populated wiki/blog content, registry IDs,
and telemetry without needing another sync, as well as private task dispatch.
It also reproduces the pre-tags schema upgrade: rows survive initialization,
the new `listed = 0` default hides them until the first sync, and subsequent
initialization preserves the published catalog.

`tests/search-store.test` runs on SQLite or the same disposable PostgreSQL setup.
It checks binary round trips, a fresh worker with constructors disabled, warm
revision checks and result-only metadata reads, unchanged and URL-only syncs,
publication/metadata races, corrupt snapshots, transaction rollback, and competing
publishers. Search HTTP and rendering compatibility remain covered by `all.tcl`.
`tests/invoke-patch-local.test` checks local invocation validation, function errors,
transport errors and task confirmation. PostgreSQL maintenance tests cover derived
snapshot invalidation and rebuilding after restore without changing backup tables.

Run `ttrek run tclsh9.1 "$PWD/tests/benchmark-search.tcl"` for a reproducible
in-memory benchmark using the checkout's registry. It reports the two blob sizes,
mapping size, native construction/loading times and complete validated build/load
times. It does not connect to production or write persistent application data.

On 2026-11-12, an x86_64 local run with Tcl 9.1, ttrie/ttrigrams 0.2.0 and the
bundled registry (101 packages, 215 versions, 599 documents) averaged the following
over 50 iterations:

| Measurement | Result |
| --- | ---: |
| Name index | 1,749 bytes |
| Trigram index | 64,552 bytes |
| JSON document mapping | 20,980 bytes |
| Native construction of both indexes | 1.15 ms |
| Native loading of both indexes | 0.14 ms |
| Complete publication build, including input preparation and validation | 8.39 ms |
| Worker load, including checksum and mapping validation | 2.91 ms |

These exclude network/database transfer time and do not measure complete Lambda
request latency. Warm requests reuse indexes and fetch only matched metadata.

Run `ttrek run tclsh9.1 tests/telemetry-maintenance.test` for lazy-loading and
private-event dispatch checks. With `TTREK_TEST_POSTGRES` pointing at a disposable
database, it also checks JSONL backup/restore, binary/text round trips, cursor
paging, truncated exports, sequence advancement, advisory locking, cleanup and
combined backup/vacuum execution. S3 upload is stubbed; no AWS resources are used.
No Docker or PostgreSQL command-line clients are required by the application.
