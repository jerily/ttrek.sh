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
- The package registry contains published package specifications independently
  of the website's own dependencies.

# Build

Install a C/C++17 toolchain, make, CMake 3.22.1+, pkg-config, git, curl, tar,
patch, Perl, and the zlib development headers. The same build script installs
the complete Tcl runtime for local development and CI:
```bash
./build.sh
```

`build.sh` downloads Tcl 9.1.0 (including Thread and SQLite) from the official
release archive and downloads jinja2-tcl from its GitHub repository. It builds
upstream cJSON separately and links it statically into the template extension;
tjson's private cJSON implementation is not used by jinja2-tcl. The interpreter
is `build/install/bin/tclsh9.1`; no sibling repository is needed. The build and
registry use the published tjson 1.0.26 and twebserver 1.47.54 release tags.

`build.sh` also builds the Valkey bindings, protobuf, Abseil, Tink and AWS SDK
libraries, then installs tconfig, rate limiting, request monitoring and session
packages. The dependency recipes and native build patches live in `build-support/`.
Completed installs are reused on subsequent runs. Set `TTREK_MAKE_THREADS` to
control build parallelism (default: 4). The script finishes by loading the real
runtime packages in a fresh Tcl interpreter and fails if any are missing or
cannot load. The native patches retain the Tink shared-library install, use the
standard system linker, fix a RapidJSON header rejected by GCC 15, and make the
pinned tink-tcl release request Tcl 9.1 when loaded.

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
The request-monitor page uses treqmon's statistics APIs and application-owned
Jinja templates, CSS and JavaScript. It preserves page-view, average-response-time
and optional active-user charts for seconds, minutes and hours, including maxima.
All assets are served locally; no template compiler or JavaScript bundler is used.

## Validation

```bash
LD_LIBRARY_PATH="$PWD/build/install/lib:$PWD/build/install/lib64" build/install/bin/tclsh9.1 tests/runtime-packages.tcl
LD_LIBRARY_PATH="$PWD/build/install/lib:$PWD/build/install/lib64" build/install/bin/tclsh9.1 tests/all.tcl
```

`tests/runtime-packages.tcl` checks installed dependencies without service mocks.
The rendering tests validate all templates and exercise the real request handlers and
renderer with isolated service fixtures, including empty collections, dependency
conditions, version ordering, HTML/URL escaping and monitor chart data. They do
not connect to Valkey, AWS or the telemetry database. CI runs them before packaging.

The optional startup smoke test needs Python 3, a local `valkey-server` executable
and free ports 8080/4433:

```bash
VALKEY_SERVER=/path/to/valkey-server python3 tests/runtime-smoke.py
```

It launches a disposable copy of the app with an isolated Valkey process, test
certificates and its own SQLite database under `build/`. It checks HTTP pages,
registry responses and browser assets without using your configuration or AWS.

# Run

After building the dependencies and browser asset, run `ttrek.sh` locally.
`run.sh` sets the library search path automatically:
```bash
./run.sh
```

## Infrastructure

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

Application connections must use TLS on port 6379 with `appuser` and that
password. `app.tcl` currently forwards only the cache host and port to the
rate-limit and request-monitor stores; TLS and credentials still need to be
wired into those clients before using this cache.

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
application also exposes registry, telemetry and static-file endpoints.

### Protections

Template lookup is restricted to the dictionary loaded from the application's
`www` directory. jinja2-tcl never evaluates Tcl from templates. Contexts retain
JSON types, ordinary output is escaped, and chart JSON is escaped into HTML data
attributes before JavaScript parses it; it is never inserted as executable script.

### Pending

The existing request-monitor and debug routes have no authentication guard in
this repository. Apply the deployment's access controls before exposing them.
