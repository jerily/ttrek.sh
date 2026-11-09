# Local development

[Documentation](readme.md) · [Project overview](../README.md)

Complete [setup](install.md) first. Run these commands from the website checkout.

## Edit website content

Documentation lives in `content/docs/`; dated blog posts live in `content/blog/`.
The public packages `web-static-wiki` and `web-static-blog` serve these directories
without a content database or browser write routes. Blog filenames use
`YYYY-MM-DD-title.md`. The first announcement is
`content/blog/2026-11-07-ttrek-1-0-0-is-now-public.md`.

Edit Markdown files locally and restart the direct server to publish changes:

```sh
ENV=LOCAL ttrek run -script start-direct
```

The **Documentation** and **Blog** links open `/docs` and `/blog`. Each worker owns
its router and directory snapshots. Mounts receive `-store`, `-prefix`, and
`-config` with `master_template` (the docs/blog bridge) and `templates` (the shared
host master). The packages retain their index, card, article and Markdown rendering;
the host master owns site navigation, so content layouts do not repeat it.
Direct serving uses the configured Valkey service and TLS settings below.

The footer's **Request Monitor** link opens `/request-monitor`. Its shared site
layout is selected by `[request_monitor] master_template` in the INI configuration,
defaulting to `request-monitor-master.html.jinja` in `www/`. Custom monitor masters
provide a `body` block and load the chart assets, as the default bridge does.
The `treqmon` package mounts the page and serves its chart script. Set
`[request_monitor] store=memory` for local history without a monitoring database,
or `store=valkey` to use the `[redis]` host, port, credentials and TLS options.
Omitting `store` selects memory in LOCAL mode and Valkey in PROD mode.
`history_max_events` sets the retained event limit. The direct server's rate
limiter still uses the configured Valkey connection independently of monitoring.

## Package and run the local services

The private registry
supplies the local mock tooling; the public registry supplies the static content
packages. `TTREK_LOCAL_CONFIG` may select a local INI for release settings.
The `package-lambda` script packages both content directories for local testing
and deployment. It calls `bin/package-lambda.sh`, the same entry point used by
the infrastructure build scripts.
Repackage the site after changing Markdown for the local Lambda stack or deployment.

To run the website through all three mocks, without Valkey or AWS:

```sh
ttrek run -script package-lambda -- --local-only
ttrek run -script start-local
```

Open `http://127.0.0.1:8080/` or `http://127.0.0.1:8080/docs`. The supervisor starts:

| Service | Default port | Responsibility |
| --- | --- | --- |
| mock-proxy-app | 8080 | Routes HTTP requests to the `prod-Api-TtrekWebsite-Function` Lambda function |
| mock-lambda-app | 3001 | Runs the packaged custom runtime and HTTP event adapter |
| mock-s3-app | 3015 | Serves public assets and the locally built release executable |

`etc/routes.json` maps `/` and `/{proxy+}` to the function. The Lambda adapter supports
payloads 1.0 and 2.0, preserves query/body data and returns base64-encoded response
bytes. Static website assets are fetched from S3 through Lambda, retaining the
browser's origin and content security policy. Package CSS is served by each
content package. Release redirects and checksum metadata use the mock
S3 endpoint and local credentials. HTTP S3 endpoints are accepted only on loopback
in LOCAL mode; production signing still requires HTTPS.

Packaging creates `dist/ttrek-sh.zip`, with Markdown directories and the public
RDS CA bundle, plus `dist/s3/ttrek-assets` and `dist/s3/ttrek-local` seed buckets.
It includes installed runtime libraries, templates and public registry recipes;
it excludes host configuration, TLS keys, Git metadata and working databases.
The release bucket contains this host's `ttrek` executable, not a published release.
`--local-only` selects the host ABI; no archive is uploaded or deployed.

The Lambda runtime uses directory snapshots, a SQLite telemetry database shared
within the local runtime data directory, and per-process request-monitor history and rate limits in memory. Copy
`etc/config.local.ini.example` to ignored `etc/config.local.ini` to adjust limits;
`TTREK_LOCAL_CONFIG` selects an alternative host file. Local files are never
packaged, and local mocks do not load the production config or call AWS.
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

CodeBuild uses the same ttrek packaging workflow for the SAM Lambda deployment
described in [Deployment](deployment.md). The older `build.sh` remains a
[public dependency bootstrap](install.md#public-dependency-bootstrap).

## Direct server

Before starting the direct server, build the [search index](registry.md#recipe-search)
with `ttrek run -script build-search` and configure Valkey and TLS as described below.

After building the dependencies and browser assets, run `ttrek.sh` locally.
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
