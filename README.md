# ttrek.sh

[ttrek](https://github.com/jerily/ttrek) registry and website

**Note** that this project is under active development.

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
- Direct HTTP and Lambda HTTP events share `tcl/site.tcl`, `tcl/routes.tcl`
  and `tcl/handlers.tcl`. Mock applications own local HTTP transport and S3 storage.
- Release checksums live in a versioned JSON manifest, separated by environment.
  Configuration selects the version; hashes from another version never substitute
  for a missing target.
- The package registry contains published package specifications independently
  of the website's own dependencies. It lives in
  [jerily/ttrek-registry](https://github.com/jerily/ttrek-registry), included here
  as the `registry` Git submodule at a pinned commit.

Clone the website with its registry:

```bash
git clone --recurse-submodules https://github.com/jerily/ttrek.sh.git
```

For an existing checkout, initialize or update the registry after pulling:

```bash
git submodule update --init --recursive
```

Make package changes in `jerily/ttrek-registry` and publish them there first.
Then update the website's pinned registry commit and commit the change in
`ttrek.sh`:

```bash
git -C registry fetch origin
git -C registry checkout --detach origin/main
git add registry
git commit -m "Update registry submodule"
```

The website reads package specifications and patches from `[registry] directory`
in the application configuration:

```ini
[registry]
directory = registry
```

The default is the `registry` submodule. Relative paths resolve against the
application root, and absolute paths can point to a separate registry checkout.
Set this in `etc/config.local.ini` for LOCAL mode or the production configuration
for PROD mode, then restart the server. All package pages and registry API routes
use this directory. The build still uses the pinned submodule for its patch files.

Recipe scripts can reference files beside their spec, for example
`"scripts": {"demo": {"file": "demo.sh"}}`. The API reads these UTF-8 files
and returns their contents as script strings, preserving compatibility with
installed-script caching. Only regular files directly in the recipe directory
are accepted; paths and symbolic links are rejected. Inline scripts also work.

Registry recipes use `if: "+static"` for optional static build settings.
Enable them with `ttrek gen-script -static` or `useFlags: ["+static"]` in the project.
Without the flag, recipes keep their normal defaults.
Static Tcl extensions are intended for embedding, not `package require` loading.

### Recipe search

`GET /registry/search?q=web` returns JSON objects with `name`, `description`, and
`match`. Ranking: exact name, prefix, substring, literal description, name typo,
description typo. Ties prefer fewer edits, greater query-trigram coverage, less
unmatched name text, then name. `distance` is omitted for prefix/substring name
matches; `coverage` is shared/total unique query trigrams for description hits.

Matching ignores ASCII case. Queries accept 1–255 ASCII letters, digits, spaces,
`.`, `_`, `+` and `-`, excluding empty queries, `.` and `..`. Encode literal `+`
as `%2B`. Invalid queries return 400; no matches returns `[]`. Queries of at most
three characters allow one edit, longer queries two. Description suggestions
require a shared trigram and a verified substring distance; below three
characters descriptions match literally.

Each worker builds ttrie 0.1.1 and ttrigrams 0.1.0 indexes at startup. All version
descriptions are indexed, with one result per package. Description hits display
the matched text; name hits use the first nonempty description in alphabetical
order. Missing descriptions are allowed. Requests reuse the snapshot; restart
after registry edits. `build.sh` installs both extensions using Tcl stubs.

The recipe API returns the selected version's `scripts` object together with
its dependencies, build instructions, USE flags and patches. Both registry
endpoints omit recipe devDependencies, following npm semantics: development
dependencies are installed only for the root project. Missing scripts
are represented as an empty object. Script bodies remain JSON strings; the
website does not execute them. The CLI saves them with the installed package
for offline `ttrek run -package PACKAGE -script NAME` and
`ttrek scripts -package PACKAGE ls|describe` commands.

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

## Binary distributions

`GET /dist/<target>/ttrek` redirects to a signed HTTPS S3 GET URL. Configure the
private distribution bucket in `[releases]` in `etc/config.local.ini` for LOCAL
mode, or the production configuration. Empty `bucket` disables downloads with
HTTP 503; it does not affect registry routes. The tracked template and local
configuration contain the same release settings:

```ini
[releases]
bucket = jerily-ttrek-app
region = eu-central-1
prefix = ttrek/1.0.0
version = 1.0.0
url_expiry_seconds = 300
checksums_file = etc/releases.json
```

The [portable release build](https://github.com/jerily/ttrek/pull/33) exports
`dist/<target>/ttrek`. Upload each executable to `<prefix>/<target>/ttrek` in the
configured bucket, using these target names:

| Target | Installer alias |
| --- | --- |
| `linux-amd64-glibc` | `x86_64-unknown-linux-gnu` |
| `linux-arm64-glibc` | `aarch64-unknown-linux-gnu` |
| `linux-amd64-musl` | `x86_64-unknown-linux-musl` |
| `linux-arm64-musl` | `aarch64-unknown-linux-musl` |
| `macos-arm64` | `aarch64-apple-darwin` |
| `macos-x86_64` | `x86_64-apple-darwin` |
| `macos-universal2` (optional) | `universal2-apple-darwin` |

For example, `/dist/linux-arm64-musl/ttrek` and
`/dist/aarch64-unknown-linux-musl/ttrek` select the same object. The existing
installer follows the redirect. Unknown targets and extensions return 404.
`public/ttrek-init` defaults to `https://ttrek.sh`, detects Linux libc and CPU,
and selects native ARM64 on Apple Silicon even under Rosetta. Intel Macs retain
the Intel target. Curl and wget verify certificates and follow the S3 redirect.
With `ENV=LOCAL`, it defaults to `http://localhost:8080`; the LOCAL homepage's
install command passes that environment setting into the script. To use local
HTTPS, set `TTREK_UPDATE_ROOT=https://localhost:4433` and trust the local certificate
through the downloader's CA configuration.

`checksums_file` is a JSON file resolved relative to the application root (or an
absolute path). The tracked `etc/releases.json` starts empty; the release upload
script in the sibling `ttrek` checkout merges SHA-256 hashes into it after all
selected uploads succeed. Its structure is environment → version → target → hash:

```json
{
  "local": {},
  "prod": {
    "1.0.0": {
      "linux-amd64-glibc": "<64-character SHA-256 of the executable>"
    }
  }
}
```

The placeholder above illustrates the structure; real entries require a valid
64-character hexadecimal digest. `ENV=LOCAL` selects `local`; production selects
`prod`. `releases.version` selects the exact version in that section. Missing
versions or targets have no checksum; malformed JSON, invalid entries, and
missing configured files fail startup. Inline `sha256_<target>` settings are
replaced by this manifest.

From the `ttrek` checkout, run `ttrek run -script upload-local -- 1.0.0` or
`ttrek run -script upload-prod -- 1.0.0`; optionally append target names.
The script defaults to this checkout's `etc/releases.json` when the repositories
are siblings. Otherwise set `TTREK_CHECKSUMS_FILE` to the configured file.
It preserves previous versions and targets and rejects changed bytes for an
already recorded production version/target. Run uploads sequentially and commit
the resulting manifest with the configuration change.

`GET /releases/latest/<target>` returns JSON with
`version`, canonical `target`, `sha256`, and a signed `url` for `ttrek self-update`.
It returns 503 if the bucket or that checksum is missing. Use an immutable prefix
per release and update the version and prefix together after uploading. Ship the
manifest with the configuration; the production build already packages `etc/`.
Both endpoints send `Cache-Control: no-store` so cached redirects cannot outlive
their signatures. Restart the application after changing configuration or hashes.
The local mock stack reads the same INI reference and `local` section at startup,
using its `ttrek-local` bucket. Packaged 1.0.0 seed binaries supply hashes only for
targets without uploaded metadata; uploaded hashes take precedence. Repackage
after runtime code changes, and restart the local stack after uploads.
Local uploads also update the S3 seed directory (`dist/s3` here by default),
because the mock's object database is disposable. Packaging preserves existing
release seed binaries; remove a seed explicitly to refresh it from the host CLI.

`aws-sdk-tcl` ^1.0.12 is a direct dependency, using AWS SDK C++ ^1.11.921 in the
registry. `build.sh` builds 1.0.12 against SDK C++ 1.11.921 and upgrades older
installed SDK modules and bindings. Each worker lazily creates an S3 client
using the configured region and the SDK's default credential provider. Configure
an AWS profile/environment locally or an ECS task role in production with
`s3:GetObject` on the release prefix. No credentials go in the release settings.
The `jerily-ttrek-app` bucket remains private; download clients receive temporary
access through signed URLs. The infrastructure declares private bucket access
and grants the application task role object-read permissions. The signer needs
valid AWS credentials. See AWS's
[presigned URL documentation](https://docs.aws.amazon.com/AmazonS3/latest/userguide/using-presigned-url.html).

# Local documentation and mock stack

Install dependencies from this directory:

```sh
ttrek sync
ttrek install -y -registry ../private-ttrek-registry -add-pubreg
```

Documentation lives in `content/docs/`; dated blog posts live in `content/blog/`.
The public packages `web-static-wiki` and `web-static-blog` serve these directories
without a content database or browser write routes. Blog filenames use
`YYYY-MM-DD-title.md`. The empty blog directory displays an empty publication index.

Edit Markdown files locally and restart the direct server to publish changes:

```sh
ENV=LOCAL ttrek run -script start-direct
```

The **Documentation** and **Blog** links open `/docs` and `/blog`. Each worker owns
its router and directory snapshots. Mounts receive `-store`, `-prefix`, `-navigation`
and `-config master_template`; only the shared master is supplied as an additional
template. Direct serving uses the configured Valkey service and TLS settings below.

`tdevops` owns packaging and local service supervision; `etc/tdevops.tcl` supplies
application staging, S3 seeds and release configuration. The private registry
supplies the local mock tooling; the public registry supplies the static content
packages. `TTREK_LOCAL_CONFIG` may select a local INI for release settings.
The `package` and `package-lambda` scripts package both content directories.
Repackage the site after changing Markdown for the local Lambda stack or deployment.

To run the website through all three mocks, without Valkey or AWS:

```sh
ttrek run -script package -- --local-only
ttrek run -script start-local
```

Open `http://127.0.0.1:8080/` or `http://127.0.0.1:8080/docs`. The supervisor starts:

| Service | Default port | Responsibility |
| --- | --- | --- |
| mock-proxy-app | 8080 | Routes HTTP requests to the `ttrek-sh` Lambda function |
| mock-lambda-app | 3001 | Runs the packaged custom runtime and HTTP event adapter |
| mock-s3-app | 3015 | Serves public assets and the locally built release executable |

`routes.json` maps `/` and `/{proxy+}` to the function. The Lambda adapter supports
payloads 1.0 and 2.0, preserves query/body data and returns base64-encoded response
bytes. Static website assets are fetched from S3 through Lambda, retaining the
browser's origin and content security policy. Package CSS is served by each
content package. Release redirects and checksum metadata use the mock
S3 endpoint and local credentials. HTTP S3 endpoints are accepted only on loopback
in LOCAL mode; production signing still requires HTTPS.

Packaging creates `dist/ttrek-sh.zip`, with Markdown directories and a fresh
telemetry schema, plus `dist/s3/ttrek-assets` and `dist/s3/ttrek-local` seed buckets.
It includes installed runtime libraries, templates and public registry recipes;
it excludes host configuration, TLS keys, Git metadata and working databases.
The release bucket contains this host's `ttrek` executable, not a published release.
`--local-only` selects the host ABI; no archive is uploaded or deployed.

The Lambda runtime uses directory snapshots, a disposable telemetry database and
per-process request-monitor history. Local mock mode has no Valkey rate limiter.
Mock object uploads and runtime state are disposable. Repackage after source
changes and restart the services to load the new snapshots.

All services bind to loopback. Custom ports and paths can be passed together:

```sh
ttrek run -script start-local -- --port 8081 --lambda-port 3002 --s3-port 3016 \
    --zip /path/to/ttrek-sh.zip --s3-dir /path/to/s3 --state-dir /tmp/ttrek-local
```

`start-lambda`, `start-proxy` and `start-s3` also run individually with the same
options. `TTREK_SITE_PREFIX` selects installed dependencies, defaulting to
`PROJECT_INSTALL_DIR` under ttrek or `ttrek-venv/local`. Ctrl-C stops the supervised
services and their workers; generated service directories are removed.

The existing `build.sh`/CodeBuild container pipeline predates this local wiki
integration. It has not been migrated to private package installation or Lambda
deployment; use the ttrek workflow above to review these local changes.

# Public dependency bootstrap

The older public-only bootstrap requires a C/C++17 toolchain, make, CMake
3.22.1+, pkg-config, git, curl, tar, patch, Perl and the zlib development headers:
```bash
./build.sh
```

`build.sh` downloads Tcl 9.1.0 (including Thread and SQLite) from the official
release archive and downloads jinja2-tcl from its GitHub repository. It builds
upstream cJSON separately and links it statically into the template extension;
tjson's private cJSON implementation is not used by jinja2-tcl. The interpreter
is `build/install/bin/tclsh9.1`; no sibling repository is needed. The build and
registry use the published tjson 1.0.26 and twebserver 1.47.54 release tags.

`ttrek.json` declares every Tcl extension installed by `build.sh` as a direct
dependency, including `tink-tcl` 20240704.0.1 and `tsession` 1.0.3. Their native
libraries remain transitive registry dependencies. Tcl's bundled SQLite package
comes with the Tcl runtime.

`build.sh` installs public runtime dependencies, including TLS-enabled Valkey and
`tink-tcl` 20240704.0.1 with Tcl stubs. Tink and RapidJSON patches live in
`registry/tink-cc/2.1.1/`. Completed installs are reused. Set `TTREK_MAKE_THREADS`
to control parallelism (default: 4). Its final package check now also expects the
static content and mock packages; use the ttrek installation above for the complete site.

Configure the Valkey service and `etc/config.ini` before running the application.
Encrypted configuration additionally requires the configured AWS credentials
and KMS access. Building the libraries and checking package loading do not
require AWS credentials.

Build the request-monitor browser asset with Node.js and npm:

```bash
npm ci --ignore-scripts
npm run build
```

This copies the pinned Chart.js UMD distribution to `public/js/chart.umd.js`.
The request-monitor page uses treqmon 2.0.0's Jinja templates and statistics APIs,
with the website's page layout and local assets. It preserves page-view,
average-response-time and optional active-user charts for seconds, minutes and hours, including maxima.
All assets are served locally; no template compiler or JavaScript bundler is used.

## Validation

```bash
ttrek run tclsh9.1 "$PWD/tests/runtime-packages.tcl"
ttrek run tclsh9.1 "$PWD/tests/all.tcl"
ttrek run tclsh9.1 "$PWD/tests/config.test"
ttrek run tclsh9.1 "$PWD/tests/static-content.test"
python3 tests/installer.py
python3 tests/runtime-smoke.py
python3 tests/local-stack.py
```

`tests/runtime-packages.tcl` loads runtime and development packages without starting services.
`tests/local-stack.py` runs the packaged site through all three installed mock
services on temporary ports. It checks documentation, HEAD/error behavior,
S3-backed asset changes, binary objects, signed release downloads and checksums,
Lambda payload 1.0 query/body handling, an unchanged archive, and shutdown cleanup.
Package before running this test. Package checks include `awss3`; release-handler tests cover target selection, signing
arguments, metadata, disabled downloads, invalid requests and signer failures.
Config tests cover manifest validation, paths, and exact environment/version
selection. The local stack test checks that uploaded metadata takes precedence
over seed hashes and the production section of the manifest.
The Python installer test uses mocked platform/download commands and disposable
homes to verify all supported targets, endpoints, Rosetta detection and overrides;
it does not download real distributions or modify the user's installation.
The rendering tests validate all templates and exercise the real request handlers and
renderer with isolated service fixtures, including empty collections, dependency
conditions, version ordering, HTML/URL escaping and monitor chart data. They do
not connect to Valkey, AWS or the telemetry database. CI runs them before packaging.

The optional startup smoke test needs Python 3, a local `valkey-server` executable
with TLS support:

```bash
VALKEY_SERVER=/path/to/valkey-server python3 tests/runtime-smoke.py
```

It launches a disposable copy of the app with an isolated Valkey process, test
certificates and its own SQLite database under `build/`. It uses disposable ports,
checks Valkey-backed history/counters and reconnects, and never uses your config
or AWS. Run it with `ENV=LOCAL` and `ENV=PROD` to check both modes.

# Run

After building the dependencies and browser asset, run `ttrek.sh` locally.
`run.sh` sets the library search path automatically. `ENV=PROD` (the default)
loads `etc/config.enc`, or `etc/config.ini` if no encrypted file exists.
`ENV=LOCAL` loads only `etc/config.local.ini` and forces the Valkey host to
`localhost`. Copy `etc/config.ini` to that ignored local file and set the local
port, username, password, CA file, and HTTPS certificate/key. Production requires
authenticated TLS; LOCAL mode accepts `ssl = false` for the loopback system service:
```bash
ENV=LOCAL ./run.sh
# or
ENV=PROD ./run.sh
```

LOCAL mode also registers the `localhost` TLS hostname for
`https://localhost:4433/`. Use a local certificate with a `DNS:localhost` subject
alternative name. To use the system `valkey-server` service on its usual port,
set `[redis]` to `host = localhost`, `port = 6379`, and `ssl = false`. Omit
`username` and `password` when the local service does not require authentication.
LOCAL mode always forces the connection host to localhost. Production still
forces TLS and requires credentials even if the configuration says `ssl = false`.

`ssl_ca_file` may be relative to the project root, for example
`local/dev-runtime/cert.pem`; the loader resolves it independently of the launch
working directory. TLS certificate options are omitted for plain TCP. Keep local
certificates and keys under ignored `local/`, and keep the machine-specific
configuration in ignored `etc/config.local.ini`.

## Infrastructure

All deployment scripts use the AWS profile `ttrek-prod-neo`, configured for
`eu-central-1`. The storage, build and application templates use the `jerily`
S3 prefix, matching the private release bucket `jerily-ttrek-app`.

For a new environment, run the scripts in `infra/` in numeric order: keys,
storage, VPC, cache, CodeBuild, then Fargate. `10-deploy-infra-storage.sh` deploys
`10-infra-storage.yml` (ECR and S3) before `20-deploy-infra-vpc0.sh` deploys
`20-infra-vpc0.yml` (networking). `25-deploy-infra-cache.sh` then deploys
`25-infra-cache.yml` (Valkey and its subnet group), importing the VPC's private
subnet and security group. Build and push the container image before deploying
Fargate.

The cache follows the Valkey 8.2 setup with one `cache.t4g.micro` node, TLS
required, an `appuser` account, and a disabled default user. Set
`TTREK_VALKEY_PASSWORD` (16-128 characters) before running the cache deployment
script; it supplies the `NoEcho` CloudFormation password parameter. User and
user-group IDs include `AppName` to avoid collisions with other deployments.
The cache stack exports `Infra-DevOps-TTREK-Cache-ValkeyClusterId` and
`Infra-DevOps-TTREK-Cache-ValkeyClusterEndpointAddress`.

`valkey-tcl` 1.0.3, `tratelimit` 1.0.1, and `treqmon` 2.0.0 are direct application
dependencies. The registry and build use libvalkey 0.5.0 with TLS enabled.
Production rate-limit counters and request-monitor history both use Valkey over
verified TLS with `appuser`. Configure `[redis]` keys `host`, `port`, `username`,
`password` and `ssl_ca_file`. Production's CA file defaults to `/etc/ssl/certs/ca-certificates.crt`;
set `/ttrek_sh/prod/redis/password` as an SSM SecureString before building the
encrypted config. The password must match the cache deployment password.

Previously `valkey-tcl` was installed transitively through `tratelimit` and
`treqmon`. Rate limits used sorted sets under `__RL__/...`; request history used
the `history_events` list, not the optional memory store. Download telemetry
uses SQLite. The registered `tsession-valkey` package was not a site dependency.

The VPC uses one availability zone. The load balancer and a single NAT gateway
have public IPs in the public subnet; Fargate and Valkey use the private subnet.
Outbound traffic uses NAT instead of VPC endpoints. Egress therefore depends
on that one availability zone.

The VPC deployment retains the `Infra-DevOps-TTREK-Base` stack name and its
remaining exports. For an existing deployment, migrate the ECR repository and
S3 bucket into `Infra-DevOps-TTREK-Storage` using CloudFormation resource
refactoring or retain/import before applying the split templates; a normal
deployment cannot move existing resources between stacks. The cache stack
creates a new Valkey replication group, so migrate any required Redis data
before retiring the old cache.


## Security

### Surface

Registry metadata and request-monitor statistics are rendered into HTML. The
application also exposes registry, telemetry and static-file endpoints, a public
read-only documentation and blog, and local mock service endpoints.

### Protections

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

### Pending

The existing request-monitor and debug routes have no authentication guard in
this repository. Apply the deployment's access controls before exposing them.
The mocks execute trusted local code and do not authenticate callers. They are
development services. Deployment configuration remains outside this local integration.

## API Gateway template

```sh
ttrek install -force -registry ../private-ttrek-registry -add-pubreg tdevops mock-proxy-app
ttrek run -package tdevops -script generate-api-gateway
```

This writes `dist/api-gateway.json` from `routes.json`. Deployment defaults live
under `apiGateway`; the CLI only selects input/output files. The template exposes
API name, stage, timeout, backend function and `AuthorizerFunction` parameters.
Authorization starts disabled because `authorizer.function` is empty. Supply an
existing Lambda name or ARN there, or through the CloudFormation parameter, to
enable it. `authorizer.excludePaths` lists exact configured paths that stay public
for every method. Add explicit routes for public pages beneath a protected catch-all.
The local mock ignores these deployment settings. Template generation does not deploy AWS resources.
