# ttrek.sh

ttrek.sh is the website and package catalog for
[ttrek](https://github.com/jerily/ttrek), the Tcl package manager. Think of it as
a library of building blocks: you find the packages you need, and the catalog
tells ttrek how to download and build them.

Visit [ttrek.sh](https://ttrek.sh) to browse packages, download ttrek, and read
guides and blog posts.

This project is under active development. Source archive fallbacks and binary
downloads redirect to signed URLs in a private S3 bucket, with separate expiry
settings; see [distributions](docs/releases.md) and [security](docs/security.md).

## Run locally

Follow the [setup guide](docs/install.md) first. It covers the required tools
and access to private development packages. Once setup is complete:

```sh
ttrek run -script package-lambda -- --local-only
ttrek run -script start-local
```

With the services running, use another terminal to initialize and publish the local data:

```sh
ttrek run -script bootstrap-local
```

Bootstrap initializes the schema, publishes the packaged content and registry,
then refreshes Package Tracker, stopping if any step fails.
Startup only opens database connections. Repeat bootstrap after starting a new
disposable local stack; use `sync-local` to publish the packaged content and registry.

Open <http://127.0.0.1:8080/> to try the website. Press Ctrl-C to stop it.

## Learn more

- [Local development](docs/local-development.md): edit content and run the website.
- [Package registry](docs/registry.md): manage the package catalog and search.
- [All documentation](docs/readme.md): setup, testing, releases, deployment and security.

## Worker loading policy

Both Lambda and the direct server support this public INI setting:

```ini
[runtime]
loading = lazy
```

`lazy` is the default. All configured routes and middleware are registered during
initialization. A matched route loads its package implementation and prepares its
resources once per worker. Anonymous navigation does not initialize accounts;
a cookie with the account name triggers the normal session verification and live
permission checks. Monitoring and rate limiting remain active for HTTP requests.

`eager` loads implementation dependencies and prewarms the same template caches
during initialization. It uses the same routes and handlers as `lazy`. SQL opens
on its first actual use in either mode; schema changes and content imports remain
explicit private tasks. This separates loading policy from connection timing.

Templates are loaded by name through `jinja2::environment`, including inherited
layouts and only executed includes. Parsed templates remain cached for the worker
lifetime, with separate environments for site, account, forum, wiki, blog, and
monitor layouts. JSON context and output are fresh for each render. Configuration
reset destroys these caches. Production artifacts are immutable; deploy a new
artifact to change templates in running Lambda workers.

Packaging/CI validates every site template and each package composed with its
site layout, independently of SQLite. SQLite-only packaging smoke checks retain
their existing skip when that driver is unavailable.

Compare modes using the same artifact and Lambda memory setting. Measure worker
initialization, the first request for each feature, and repeated warm requests
separately: lazy loading saves unused work but shifts required loading into a
feature's first request. New Lambda workers each have their own caches.
