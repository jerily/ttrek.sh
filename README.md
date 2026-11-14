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
ttrek run -script initdb-local
ttrek run -script sync-local
```

Startup only opens database connections. Repeat these tasks after starting a new
disposable local stack; use `sync-local` to publish the packaged content and registry.

Open <http://127.0.0.1:8080/> to try the website. Press Ctrl-C to stop it.

## Learn more

- [Local development](docs/local-development.md): edit content and run the website.
- [Package registry](docs/registry.md): manage the package catalog and search.
- [All documentation](docs/readme.md): setup, testing, releases, deployment and security.


## Accounts

`web-user` is mounted at `/user`, sharing the existing worker-owned SQL connection
and site layout. Registration and recovery require CAPTCHA. Site account defaults
include `password_min_length=6`, `registration_captcha=true`, required email
verification, first/last-name collection, and login CAPTCHA after two password
failures. CAPTCHA length/alphabet and optional display-name/username collection
are configurable in `[account]`; the latter two default to false. See the local
web-user checkout's `MOUNTING.md` for the complete policy.

The login form offers an unchecked “Stay signed in” option. Selecting it keeps
the session for 30 days, configured with `[account] persistent_session_ttl=2592000`.
Otherwise the cookie lasts for the browser session and the server session expires
after 12 hours. MFA must complete before a persistent cookie is issued.

Install the account dependencies from the registry with `ttrek install -y`.
To work on sibling `web-user` or `tcaptcha` checkouts, install their CMake
packages over the local copies after installing native dependencies:

```sh
cmake -S ../web-user -B build/local-web-user -DBUILD_TESTING=OFF \
  -DCMAKE_INSTALL_PREFIX="$PWD/ttrek-venv/local"
cmake --install build/local-web-user
cmake -S ../tcaptcha -B build/local-tcaptcha -DBUILD_TESTING=OFF \
  -DCMAKE_INSTALL_PREFIX="$PWD/ttrek-venv/local"
cmake --install build/local-tcaptcha
```

LOCAL creates persistent development keys in `account-keys.json` beside the
SQLite runtime database, with private file permissions. Keep that file while
retaining the database. Codes are shown only in LOCAL; mail is disabled there by
default. Set `[account] origin` to the exact browser origin if the proxy port or
hostname differs from `http://localhost:8080`.

PROD requires persistent SecureString SSM values under `/ttrek_sh/prod/account/`:
`aead_keyset` (Tink AES256_GCM JSON), `mac_keyset` (Tink HMAC_SHA256 JSON), and
`email_hash_salt` (a random persistent salt). The production configuration template
includes those keys plus SES sender/region. Generate encrypted configuration with
the existing tconfig workflow; never put populated keysets in tracked INI files.
Production account messages use SES in `eu-central-1`, from `noreply@ttrek.sh`.
Verification, password reset, and account security notifications are enabled by
`[account] email_enabled=true`; `verification_emails_enabled=true` enables the
verification messages specifically. The SES SDK comes from the `web-user`
dependencies and is checked during packaging. The function role already grants SES
sending against the identity and configuration set exported by the SES stack.
The `ttrek.sh` sender identity must be verified in that region.

Before serving an upgraded database, invoke `task_initdb_website`; it applies the
account schema and migrates legacy pending registrations. Startup does not perform
schema changes. Existing verified accounts and still-valid verification sessions
are preserved. Back up an existing database before migration.

For local maintenance, run `ttrek run -script prune-accounts`. The SAM template
defines an EventBridge Scheduler event invoking the same Lambda every five minutes
with the following private payload:

```json
{"source":"ttrek.patch","task":"task_prune_accounts"}
```

The task deletes at most 500 expired registrations, 500 expired sessions (including
CAPTCHA challenges), and 500 expired counters per pass, plus challenges attached to
deleted registrations. `[account] cleanup_grace_period=3600` retains expired records
for an extra hour before deletion; sessions and codes still become invalid at expiry.
The task reports counts in `completed`. HTTP requests cannot select this private path.

The SAM parameters `AccountCleanupSchedule` (default `rate(5 minutes)`) and
`AccountCleanupState` (`ENABLED` or `DISABLED`) control the schedule. Cron expressions
use America/New_York. Initialize the account schema before enabling it. Increase
the frequency if a pass repeatedly reaches the batch limit. The CodeBuild role
template includes permissions for the schedule and its dedicated invocation role;
apply that infrastructure update before deploying the updated application stack.
The schedule is created when the SAM template is deployed.
