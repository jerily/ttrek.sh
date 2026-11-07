# Set up ttrek.sh

[Documentation](readme.md) · [Project overview](../README.md)

Run the commands in this guide from the website checkout unless stated otherwise.

## Requirements

- Install the [ttrek command-line tool](https://github.com/jerily/ttrek/blob/main/docs/install.md)
  and its build tools, including C/C++ compilers, CMake and Make.
- Install Node.js 22 and npm to build the browser assets.
- The complete development setup needs access to `private-ttrek-registry`,
  `tdevops` and the private mock-tool source repositories. The commands below
  expect the private registry checkout at `../private-ttrek-registry`.

The local preview runs without AWS or Valkey. Running the direct server has
additional [configuration requirements](local-development.md#direct-server).

## Get the source

Clone the website with its registry:

```bash
git clone --recurse-submodules https://github.com/jerily/ttrek.sh.git
cd ttrek.sh
```

For an existing checkout, initialize or update the registry after pulling:

```bash
git submodule update --init --recursive
```

## Install dependencies

Install dependencies from this directory:

```sh
ttrek sync
ttrek install -y -registry ../private-ttrek-registry -add-pubreg
```

To refresh the private development dependency:

```sh
ttrek install -y -D -registry ../private-ttrek-registry -add-pubreg tdevops
```

## Build browser assets

Build browser assets with Node.js 22 and npm (build prerequisites, not ttrek
runtime dependencies):

```bash
ttrek run -script build-assets
```

This named project script runs `npm ci --ignore-scripts` and `npm run build`.
Rollup bundles `assets/js/search.js` with the pinned `throttle-debounce` package
into `public/js/search.js`. Chart.js's pinned UMD distribution is copied to
`public/js/chart.umd.js`; library licenses travel beside the generated files.
Generated assets and `node_modules` are ignored. All browser assets are served
locally; Node and npm are not included in the Lambda runtime.

## Start a local preview

```sh
ttrek run -script package -- --local-only
ttrek run -script start-local
```

Open <http://127.0.0.1:8080/>. Press Ctrl-C to stop the services.
Packaging builds the search index automatically. See [local development](local-development.md)
for content edits, custom ports and running the direct server.

## Public dependency bootstrap

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
static content and mock packages; use the [ttrek installation](#install-dependencies)
for the complete site.

Configure the Valkey service and `etc/config.ini` before running the application.
Encrypted configuration additionally requires the configured AWS credentials
and KMS access. Building the libraries and checking package loading do not
require AWS credentials.
