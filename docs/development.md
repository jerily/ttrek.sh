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
  Packages read Markdown directories into immutable snapshots per worker.
  The host supplies trusted layouts. Restart workers to publish source changes.
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
  and the generated, ignored `search-index.json`. Search workers load this file;
  direct builds and Lambda packaging generate it before startup.
- `bin/`: local command launchers. `tdevops` supplies the shared Lambda runtime;
  `etc/lambda.json` declares the function and `tcl/lambda.tcl` owns app callbacks.
- `tcl/`: application modules; `www/`: Jinja templates; `schemas/`: request schemas.
- `assets/js/`: browser source bundled by Rollup; `content/` and `public/`:
  authored content and public assets; `registry/`: pinned
  package recipes. `build/`, `dist/`, and `var/` contain generated output or state.

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
renderers. The monitor also receives its versioned Chart.js URL. Startup and
packaging fail if a referenced asset is missing or its fingerprint is incorrect.
Generated files are ignored by Git and included in the Lambda archive and S3 seed.

The shared asset handler reads exact bytes and sends a quoted SHA-256 `ETag`.
Fixed CSS/JS/SVG URLs use `Cache-Control: no-cache`: clients may store them but
must revalidate before reuse, so edits are visible immediately. Matching
`If-None-Match` values (strong, weak, lists or `*`) produce an empty `304` with the
same ETag and cache policy. GET and HEAD work in direct HTTP and Lambda, including
the mock-S3 backend. Changed bytes produce a new ETag and a `200` response.

The shared layout links to `/assets/favicon.svg` and a `/favicon.ico` fallback
with 16, 32 and 48 pixel sizes. Both use `Cache-Control: public, max-age=7776000`
(three months, defined as 90 days), with the same ETag and GET/HEAD support.
The authored SVG and ICO live under `public/` and are included in the Lambda
archive and mock-S3 seed without an asset build.

Verified fingerprint URLs use `Cache-Control: public, max-age=31536000, immutable`.
An asset whose bytes do not match its filename is rejected with `404, no-store`.
Ordinary host HTML uses `no-cache`; package-owned HTML keeps its stricter
`no-store` policy. Build output retains previous fingerprints. Deployment builds
restore and preserve this history as described in [Deployment](deployment.md).

`tcl/responses.tcl` uses Tcl's `zlib gzip` for compressible HTML, CSS, JavaScript,
JSON, text and SVG responses of at least 1 KiB when gzip is accepted and reduces
the size. It honors encoding quality values, preserves `Vary` fields, and skips
already encoded, partial and `no-transform` responses. Gzip and identity assets
have distinct strong ETags based on their actual bytes. HEAD and conditional
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
There is no app-local `lambda/` directory. `devops/prepare-lambda.tcl` builds the
search snapshot before packaging; telemetry initializes its selected backend at
runtime. [Telemetry](telemetry.md) uses tpersist with SQLite only in LOCAL and
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

`[request_monitor] store` selects `memory` or `valkey`; the default is memory in
LOCAL mode and Valkey in PROD mode. `history_max_events` bounds retained history.
Both direct HTTP and Lambda use the package's middleware and store implementations.
The Valkey store receives `[redis]` connection, ACL and TLS settings. Memory uses
treqmon's shared-variable store within a process; different processes have separate history.

The shared footer links to the CLI source, public registry and request monitor.
The host renders the footer year from the system clock on each request, including
documentation, blog and monitor pages.

See [setup](install.md) for dependencies, [testing](testing.md) for validation,
and [security](security.md) for trust boundaries and current limitations.

## Content images

Both static packages (0.1.1+) accept a private S3 bucket and an image directory
from the host. Configure direct-server and Lambda startup using:

```ini
[content_images]
bucket=jerily-ttrek-app
region=eu-central-1
directory=content
prefix=ttrek/content/images
url_expiry_seconds=3600
```

`directory` is relative to the site root (or an absolute trusted directory).
With the configuration above, put shared images under `content/images/` and use
`![Architecture](images/architecture.svg)` in either docs or blog Markdown,
including Markdown in nested folders. Alternatively, set `directory=content/images`
and use `![Architecture](architecture.svg)`. Image paths always start at this
configured directory; `..`, absolute/external image URLs, backslashes, encoded
traversal and symlinks are rejected. The directory must exist.

An empty bucket disables image hosting. Each worker shares one `awss3` client
between the packages and creates snapshots at startup. Creation uploads only
missing content-hashed objects with their MIME type. Page rendering signs fresh
URLs without additional S3 requests. The SDK requires `aws-sdk-tcl-s3` 1.0.17+
for its optional file-upload MIME type. Image hashes use Tcllib's `sha256`.

The local Lambda stack overrides the bucket to `ttrek-local` and uses its loopback
S3 mock, with dummy credentials. Direct LOCAL runs may set `endpoint` to a loopback
HTTP mock explicitly. HTTP endpoints are rejected in PROD. No live AWS upload is
performed by the tests or by the artifact-packaging smoke check.

For deployment, match the SAM `ContentImagesBucket` and `ContentImagesPrefix`
parameters to the configuration. The execution role lists only that prefix and
gets/puts only its objects. Existing images and old content-hashed objects are
never deleted; manage retention separately. If image files change, recreate the
snapshots (normally by restarting). Already-open pages may require a reload after
the signed URLs expire.
