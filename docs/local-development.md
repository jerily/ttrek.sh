# Local development

[Documentation](readme.md) · [Project overview](../README.md)

Complete [setup](install.md) first. Run these commands from the website checkout.

## Edit website content

Documentation lives in `content/docs/`; dated blog posts live in `content/blog/`.
The public packages `web-static-wiki` and `web-static-blog` serve database content
without browser write routes. Blog filenames use `YYYY-MM-DD-title.md`.

Edit Markdown, repackage, and restart the local services. Run `initdb-local`, then
`sync-local`, against the running local Lambda to publish the packaged files.
Neither startup nor HTTP requests import Markdown, upload content images, create
schemas, or build search indexes. Each worker owns its router and loads search
indexes lazily from the published database snapshot.

The footer's **Request Monitor** link opens `/request-monitor`. Its shared site
layout is selected by `[request_monitor] master_template` in the INI configuration,
defaulting to `request-monitor-master.html.jinja` in `www/`. Custom monitor masters
provide a `body` block and load the chart assets, as the default bridge does.
The `treqmon` package mounts the page and serves its chart script. Monitoring
always uses Valkey with the `[redis]` port, credentials and TLS options.
`[request_monitor] store` may be omitted or set to `valkey`; remove any old
`store=memory` setting. LOCAL mode restricts the connection to localhost.
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

Start your local Valkey service and configure its connection in the required
`[redis]` section of your local INI, then run the website through all three mocks
without AWS:

```sh
ttrek run -script package-lambda -- --local-only
ttrek run -script start-local
```

In another terminal, initialize the database and synchronize the website:

```sh
ttrek run -script initdb-local
ttrek run -script sync-local
```

These call the private `task_initdb_website` and `task_sync_website` tasks through
the mock Lambda Invoke API. Sync imports docs, blog posts and registry metadata,
uploads missing content images, and publishes the search indexes. Initialization
preserves existing rows. Search returns 503 until a snapshot has been published.


Open `http://127.0.0.1:8080/` or `http://127.0.0.1:8080/docs`. The supervisor starts:

| Service | Default port | Responsibility |
| --- | --- | --- |
| mock-proxy-app | 8080 | Routes HTTP requests to the `prod-Api-TtrekWebsite-Function` Lambda function |
| mock-lambda-app | 3001 | Runs the packaged custom runtime and HTTP event adapter |
| mock-s3-app | 3015 | Serves public assets and the locally built release executable |

`start-local` and `start-lambda` fail before starting services if the selected
local INI has no `[redis]` section. They use your configured Valkey service and
never start or stop it, generate connection settings, or delete its data.

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

The Lambda runtime uses a SQLite database for content, catalog metadata, search
snapshots and telemetry, shared within the local runtime data directory. Monitor
history is shared through Valkey; local Lambda rate limits remain in memory per
process. Copy
`etc/config.local.ini.example` to ignored `etc/config.local.ini` to adjust limits;
`TTREK_LOCAL_CONFIG` selects an alternative host file. Local files are never
packaged, and local mocks do not load the production config or call AWS.
Mock object uploads and runtime state are disposable. Repackage after source
changes and restart the services, then run `initdb-local` and `sync-local` again.
The stopped stack removes its disposable database.

All services bind to loopback. Custom ports and paths can be passed together:

```sh
ttrek run -script start-local -- --port 8081 --lambda-port 3002 --s3-port 3016 \
    --zip /path/to/ttrek-sh.zip --s3-dir /path/to/s3 --state-dir /tmp/ttrek-local
```

Use the matching Lambda port for the patch scripts:

```sh
ttrek run -script initdb-local -- --lambda-port 3002
ttrek run -script sync-local -- --lambda-port 3002
```

Both also honor `TTREK_LAMBDA_PORT` (default 3001). The shared helper always
connects to `127.0.0.1`, reads the function name from `etc/lambda.json`, and fails
on HTTP errors, Lambda function errors, or unconfirmed task completion.
To republish search indexes after editing database metadata without importing
recipes, run `bin/invoke-patch-local.sh task_publish_search`.

`start-lambda`, `start-proxy` and `start-s3` also run individually with the same
options. `TTREK_SITE_PREFIX` selects installed dependencies, defaulting to
`PROJECT_INSTALL_DIR` under ttrek or `ttrek-venv/local`. Ctrl-C stops the supervised
services and their workers; generated service directories are removed.

CodeBuild uses the same ttrek packaging workflow for the SAM Lambda deployment
described in [Deployment](deployment.md). The older `build.sh` remains a
[public dependency bootstrap](install.md#public-dependency-bootstrap).
