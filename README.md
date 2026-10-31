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

Install a C/C++17 toolchain, make, CMake 3.22.1+, pkg-config, curl, tar, and the
zlib development headers. Use the following script to build the local Tcl,
template engine, tjson, OpenSSL, and web server dependencies:
```bash
./build.sh
```

`build.sh` downloads Tcl 9.1.0 (including Thread and SQLite) from the official
release archive and downloads jinja2-tcl from its GitHub repository. It builds
upstream cJSON separately and links it statically into the template extension;
tjson's private cJSON implementation is not used by jinja2-tcl. The interpreter
is `build/install/bin/tclsh9.1`; no sibling repository is needed.

The deployment build, `./build-new.sh`, also installs the configuration,
rate-limiting, monitoring, session, Valkey and AWS dependencies required by
`app.tcl`. Those services and `etc/config.ini` must be configured to run the full
application. CI uses this deployment build.

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
LD_LIBRARY_PATH="$PWD/build/install/lib" build/install/bin/tclsh9.1 tests/all.tcl
```

The tests validate all templates and exercise the real request handlers and
renderer with isolated service fixtures, including empty collections, dependency
conditions, version ordering, HTML/URL escaping and monitor chart data. They do
not connect to Valkey, AWS or the telemetry database. CI runs them before packaging.

# Run

Use the following shell script to run `ttrek.sh` locally:
```bash
./run.sh
```

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
