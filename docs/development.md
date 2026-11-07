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
- Home, registry, documentation and blog pages share `www/master.html.jinja` and
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

## Shared runtime and packaging

`tdevops` 0.2.0 owns the shared Lambda runtime, packaging and local service supervision; `etc/tdevops.tcl` supplies
application staging, S3 seeds and release configuration. `etc/lambda.json` selects
`prod-Api-TtrekWebsite-Function`, `tcl/lambda.tcl`, its initializer and request handler. The application
keeps its HTTP event mapping, telemetry and release settings; tdevops supplies the
bootstrap, Runtime API loop, package-path setup and generated local template.
There is no app-local `lambda/` directory. `devops/prepare-lambda.tcl` builds the
search snapshot and telemetry seed before packaging.

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

The request-monitor page uses treqmon 2.0.0's Jinja templates and statistics APIs,
with the website's layout and local Chart.js asset. The host renders the footer
year from the system clock on each request, including documentation and blog pages.

See [setup](install.md) for dependencies, [testing](testing.md) for validation,
and [security](security.md) for trust boundaries and current limitations.
