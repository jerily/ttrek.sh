# Development

[Documentation](readme.md) · [Project overview](../README.md)

## Requirements and principles

- The website requires Tcl 9.1 and uses [jinja2-tcl](https://github.com/jerily/jinja2-tcl)
  exclusively. Templates are trusted application files in `www/*.html.jinja`.
- Request handlers prepare explicitly typed JSON through tjson. Templates render
  data and contain no Tcl code. Plain strings are automatically HTML-escaped;
  package names and versions in links are also URL-encoded.
- Each worker loads and validates the complete template dictionary at startup.
  Restart the server after editing templates. Missing includes and invalid
  templates fail startup.
- Documentation and blog content use `web-static-wiki` at `/docs` and
  `web-static-blog` at `/blog`, mounted on the host's `tpathexp` router.
  Both LOCAL and PROD query content rows through `tpersist`; explicit patch tasks
  prepare the database content. The host supplies trusted layouts. Repackage and
  restart local workers after source edits, then run `initdb-local` and `sync-local`.
- Home, registry, documentation, blog and request-monitor pages share `www/master.html.jinja` and
  `public/css/styles.css` for
  typography, navigation, content width and footer layout. The wiki/blog host
  layouts use scoped `docs.css` for package-rendered content, without loading
  the packages' standalone site styles. Search styles contain only search and
  homepage components.
- Direct HTTP and Lambda HTTP events share `tcl/site.tcl`, `tcl/routes.tcl`
  and `tcl/handlers.tcl`. Mock applications own local HTTP transport and S3 storage.
- Release checksums live in a versioned JSON manifest, separated by environment.
  Configuration selects the version; hashes from another version never substitute
  for a missing target.
- The package registry contains published package specifications independently
  of the website's own dependencies. It lives in
  [jerily/ttrek-registry](https://github.com/jerily/ttrek-registry), included here
  as the `registry` Git submodule at a pinned commit.

## Directory layout

- `devops/`: deployment configuration (`sam-template.yaml`, `appspec.yml`, `buildspec.yml`),
  CodeDeploy hooks in `codedeploy-scripts/`, and CloudFormation templates and
  launchers in `infra/`.
- `etc/`: application configuration, proxy/API Gateway routes, release checksums,
  and optional offline search snapshots. Website search reads database metadata.
- `bin/`: local command launchers. `tdevops` supplies the shared Lambda runtime;
  `etc/lambda.json` declares the function and `tcl/lambda.tcl` owns app callbacks.
- `tcl/`: application modules; `www/`: Jinja templates; `schemas/`: request schemas.
- `assets/js/`: browser source bundled by Rollup; `content/` and `public/`:
  authored content and public assets; `registry/`: pinned
  package recipes. `build/`, `dist/`, and `var/` contain generated output or state.

## Project commands

`ttrek.json` references executable scripts through `file`, with optional preset
arguments in `args`. Pass runtime arguments after `--`, for example:

```sh
ttrek run -script package-lambda -- --local-only --output "build/site review.zip"
ttrek run -script start-local -- --help
```

Arguments pass through literally, including spaces. `build-assets` installs the
locked npm dependencies and forwards runtime arguments to the asset build.

## Browser assets and caching

Run `ttrek run -script build-assets` after editing CSS or browser JavaScript, then
restart workers (and repackage when using the local Lambda stack). Rollup bundles
clipboard, its initializer and search into `public/js/site.js`. Its final build
step combines Pure, responsive grids, shared layout and scoped page styles into
`public/css/site.css`, copies vendor files, fingerprints CSS/JS bytes with SHA-256,
and writes `public/asset-manifest.json`. Generated URLs
look like `/assets/versioned/css/site.0123456789abcdef.css`. The first 16 hex
characters identify the content. Fixed URLs remain available for existing clients.

Templates reference `asset_urls['/css/site.css']`. The homepage and package pages
load one stylesheet and one script; documentation/blog omit the unused script,
and the monitor retains its dedicated chart scripts. The root layouts bind the
manifest at startup, so inherited blocks work in host, wiki, blog and monitor
renderers. The monitor also receives its versioned Chart.js URL. Startup validates
the manifest entries without reading or hashing the referenced asset files.
Generated files are ignored by Git and included in the Lambda archive and S3 seed.

The shared asset handler serves exact bytes and uses the manifest's precomputed
fingerprint for the `ETag`. Retained versioned URLs use their embedded fingerprint.
Assets without a manifest entry or versioned fingerprint have no ETag.
Fixed CSS/JS/SVG URLs use `Cache-Control: no-cache`: clients may store them but
must revalidate before reuse. Rebuild assets and restart workers to update
manifest-derived validators after edits. Matching
`If-None-Match` values (strong, weak, lists or `*`) produce an empty `304` with the
same ETag and cache policy. GET and HEAD work in direct HTTP and Lambda, including
the mock-S3 backend.

The shared layout links to `/assets/favicon.svg` and a `/favicon.ico` fallback
with 16, 32 and 48 pixel sizes. Both use `Cache-Control: public, max-age=7776000`
(three months, defined as 90 days), with GET/HEAD support and no ETag.
The authored SVG and ICO live under `public/` and are included in the Lambda
archive and mock-S3 seed without an asset build.

Fingerprint URLs use `Cache-Control: public, max-age=31536000, immutable`.
The handler trusts build-time fingerprints without checking asset contents.
Ordinary host HTML uses `no-cache`; package-owned HTML keeps its stricter
`no-store` policy. Build output retains previous fingerprints. Deployment builds
restore and preserve this history as described in [Deployment](deployment.md).

`tcl/responses.tcl` uses Tcl's `zlib gzip` for compressible HTML, CSS, JavaScript,
JSON, text and SVG responses of at least 1 KiB when gzip is accepted and reduces
the size. It honors encoding quality values, preserves `Vary` fields, and skips
already encoded, partial and `no-transform` responses. Gzip and identity assets
have distinct ETags: gzip adds a `-gzip` suffix to the existing validator without
hashing the compressed bytes. HEAD and conditional
requests select the representation before removing the body. The direct server's
own compression is disabled to avoid compressing twice; Lambda returns the gzip
bytes through its existing base64 response envelope.

Outside `ENV=LOCAL`, a supplied Host other than `ttrek.sh` redirects with `302`
to `https://ttrek.sh`, preserving the path and query string. Host matching is
case-insensitive, and forwarded-host headers do not override it. LOCAL keeps the
localhost development workflow available.

## Shared runtime and packaging

`tdevops` 0.2.0 owns the shared Lambda runtime, packaging and local service supervision; `etc/tdevops.tcl` supplies
application staging, S3 seeds and release configuration. `etc/lambda.json` selects
`prod-Api-TtrekWebsite-Function`, `tcl/lambda.tcl`, its initializer and request handler. The application
keeps its HTTP event mapping, telemetry and release settings; tdevops supplies the
bootstrap, Runtime API loop, package-path setup and generated local template.
There is no app-local `lambda/` directory. Search indexes are published by sync
and loaded lazily per worker. Both PROD and LOCAL startup open database connections
only; initialization and synchronization use explicit patch tasks. [Telemetry](telemetry.md) uses tpersist with SQLite only in LOCAL and
PostgreSQL only in PROD. Backend drivers are loaded only on connection.

## Request validation

Each worker uses [topenapi](https://github.com/jerily/topenapi) 0.2.0 to cache the
inline operation schemas in `schemas/`. Its C adapter normalizes twebserver
request dictionaries. The telemetry handler uses the validator's native `bind`
command to create typed local variables from explicitly selected path and body
fields. Validation and field extraction finish before variable assignment; the
handler does not parse the JSON body a second time. The build installs the
extension with Tcl stubs; restart the application after editing schemas.

The search endpoint validates a single `q` parameter against `schemas/search.json`
after URL decoding. Repeated values, invalid characters and oversized queries
return HTTP 400. Existing search normalization and ranking remain in the search
module.

`POST /telemetry/collect/:package_name/:package_version` validates paths, media
type and body using `schemas/telemetry-collect.json` before recording an event.
It requires `application/json`, action `install`, outcome `success` or `failure`,
a JSON boolean `is_toplevel`, and nonempty string `os`/`arch` values of at most
64 characters. Malformed JSON, missing fields and wrong types return HTTP 400
with a generic message. Valid requests retain the existing telemetry event and
HTTP 200 response. Additional body fields are accepted. The CLI already sends
this typed JSON contract.

## Request monitoring and shared layout

The request-monitor page is mounted by treqmon 2.1.0 on the site's `tpathexp`
router, with the website's layout and local Chart.js asset. There is no site-local
monitor handler, rendering module or monitoring middleware. Set `master_template` in the
INI's `[request_monitor]` section to a trusted filename in `www/`; the default is
`request-monitor-master.html.jinja`. Both the direct server and Lambda pass this
setting to the package's `-config master_template`, along with the shared named
templates, just like the wiki/blog mounts. The selected master supplies a `body`
block and is resolved and validated at startup.
The default bridge inherits the shared site master and loads the monitor's scoped
CSS and the package's `/request-monitor/_assets/charts.js`. Missing templates fail startup.
Chart colors come from the site's `--treqmon-chart-color` and `--treqmon-chart-fill`.

Request monitoring uses Valkey in both LOCAL and PROD modes. The optional
`[request_monitor] store` setting accepts only `valkey`; `history_max_events` bounds retained history.
Both direct HTTP and Lambda use the package's middleware and store implementations.
The Valkey store receives `[redis]` connection, ACL and TLS settings and shares
history across workers and processes. A `[redis]` section is required; local
launchers fail if it is missing and never manage the Valkey service.

The shared footer links to the CLI source, public registry and request monitor.
The host renders the footer year from the system clock on each request, including
documentation, blog and monitor pages.

See [setup](install.md) for dependencies, [testing](testing.md) for validation,
and [security](security.md) for trust boundaries and current limitations.

## Content images

The static packages accept a private S3 bucket and an image directory from the
host. Use web-static-blog 0.1.2+ and web-static-wiki 0.1.3+ for separate build and
runtime upload modes. Configure `devops/config.prod.ini` for the production build,
`etc/config.local.ini` for local development, or `etc/config.ini` for direct PROD:

```ini
[content_images]
bucket=jerily-ttrek-app
region=eu-central-1
directory=content/docs
prefix=ttrek/content/images
url_expiry_seconds=3600
```

`directory` is relative to the site root (or an absolute trusted directory for
direct-server use). Production Lambda images must be bundled under `content/`.
With the configuration above, put images under `content/docs/images/` and use
`![Architecture](images/architecture.svg)` in Markdown files directly under
`content/docs/`. These paths work in local Markdown previews as well as on the
website. The website's blog mount also uses this configured image directory.
The docs mount uses `-exclude_from_navigation {images}` (web-static-wiki 0.1.2+)
to keep the screenshot folders out of directory listings while retaining image
discovery and rendering.
Image paths on the website always start at the configured directory, including
for Markdown in nested folders; they are not resolved from each document's
location. `..`, absolute/external image URLs, backslashes, encoded traversal and
symlinks are rejected. The directory must exist.

An empty bucket disables image hosting locally; production packaging and uploads
require a bucket. Each worker shares one `awss3` client between the packages.
Both modes query stored content when requested and sign URLs using the stored image
keys. LOCAL uses SQLite and PROD uses PostgreSQL. It does not scan directories, render Markdown, or hash images at startup.
`task_sync_website` performs those operations through each package's `sync` proc.
The SDK requires `aws-sdk-tcl-s3` 1.0.17+; maintenance image hashes use `::twebserver::sha256`.

The local Lambda stack overrides the bucket to `ttrek-local` and uses its loopback
S3 mock, with dummy credentials. Direct LOCAL runs may set `endpoint` to a loopback
HTTP mock explicitly. HTTP endpoints are rejected in PROD. No live AWS upload is
performed by the tests or by the artifact-packaging smoke check.

CodeBuild runs `devops/upload-content-images.tcl` after artifact validation and
before `sam deploy`, reading the generated production image settings without
decrypting application secrets. Both content collections are validated before
uploading; S3 failures fail the build. The ZIP check verifies that the packaged
image paths, bytes and settings match what the build will upload.

For deployment, match the CodeBuild and SAM `ContentImagesBucket` and
`ContentImagesPrefix` parameters to the configuration. CodeBuild lists the image
prefix and puts missing objects. The Lambda role can also list/put this prefix
for the explicit sync task, and get images for signed downloads. Existing images and old content-hashed objects are
never deleted; manage retention separately. If content or image files change, run `task_sync_website` against the deployed
website revision. Existing database readers see the changes on their next query. Already-open pages may require a reload after
the signed URLs expire.
