# Telemetry storage and maintenance

Telemetry belongs to the website. `tcl/telemetry.tcl` uses `tpersist` for schema,
transactions, dimension lookup, events and statistics. Drivers load only when a
connection needs them: `tdbc::sqlite3` for `ENV=LOCAL`, `tdbc::postgres` for
`ENV=PROD` (also the default when ENV is unset).

## Storage

- Direct LOCAL server: `data/telemetry.sqlite3` under the checkout.
- Local Lambda: `telemetry.sqlite3` under `TTREK_LOCAL_RUNTIME_DATA`; the local
  launcher supplies its runtime data directory. Without that override the
  directory is `/tmp/ttrek-local`. Workers share this file until local state is
  removed. No telemetry database is packaged into the Lambda ZIP.
- PROD: the `[postgres]` configuration selects the endpoint, database, username,
  password, port (default 5432) and connect timeout (default 5000 ms). The backend
  always uses PostgreSQL and `sslmode=verify-full`. The bundled public AWS RDS CA
  file is `etc/rds-global-bundle.pem`; `PGSSLROOTCERT` can select a different CA
  for a test server. Obtain bundle updates from
  [AWS's RDS trust store](https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem).

Tables are created only by explicit initialization. Both LOCAL and PROD startup
only connect. The private `task_initdb_website` invocation provisions schemas;
locally, run `ttrek run -script initdb-local`. Existing LOCAL telemetry
remains in place. Environment registrations and package/platform dimensions are
shared across workers; events commit atomically. Whole transactions retry bounded
SQLite lock conflicts and PostgreSQL deadlocks/serialization failures. Schema
initialization also handles concurrent maintenance invocations. Descriptions
are not indexed, so the registration API's 65,535-character limit does not exceed
PostgreSQL's index-entry limit. Package statistics query the requested package
and version through `tpersist`, grouped by OS and architecture; they are not preloaded.

Old production Lambda SQLite files were temporary per-environment files. They are
not imported into PostgreSQL by this change.

## Deploy

Use the same AWS account/region as the website (scripts default to `eu-central-1`
and profile `ttrek-prod-neo`). The storage and keys stacks must already exist.
Nothing is deployed by editing these files.

1. **Redeploy both changed IAM policies**, using an administrator profile:
   `AWS_PROFILE=admin devops/infra/00-deploy-iam-policy.sh`.
   Then run `devops/infra/10-deploy-infra-storage.sh` to apply seven-day backup
   expiration on the existing bucket.
2. Update the network: `devops/infra/20-deploy-infra-vpc0.sh`.
3. In SSM Parameter Store create **`/ttrek_sh/prod/postgres/password`** as a
   **SecureString**, encrypted with the Keys stack KMS key. Use 8–128 printable
   ASCII characters excluding spaces, `/`, `@` and double quotes. The password
   must be in the deployment region. Do not put it in tracked INI files.
4. Run `devops/infra/38-deploy-infra-rds-postgres.sh`. It reads the password from
   SSM and deploys `Infra-DevOps-TTREK-Postgres`. The decrypted value goes through
   memory/stdin into a `NoEcho` parameter, never a file, argument or log. Only
   Python 3 and AWS CLI are required; there is no separate maintenance artifact.
5. Create the remaining String parameters manually: `/ttrek_sh/prod/postgres/host`
   from the stack's `PostgresDBEndpointAddress` output, `/database` =
   `ttrek_telemetry`, and `/username` = `ttrek_admin`.
6. Redeploy `30-deploy-codebuild.sh`, then rebuild/deploy the website. The build
   resolves SSM configuration and encrypts the password into the website artifact.
   The SAM update grants backup writes, enables asynchronous retries, and raises
   the website Lambda timeout to 300 seconds. Its memory stays at 256 MiB.

When upgrading the previous maintenance stack, its Lambda, SSM endpoint, separate
schedules and stack-owned host/database/username parameters are removed. Recreate
those three parameters after the RDS stack update and before the website build.
The password remains operator-managed. Existing database resources and their
security-group descriptions are preserved to avoid replacements. The alarm now
tracks errors from the website Lambda, including maintenance failures.

The RDS instance is PostgreSQL 17, `db.t4g.micro`, Single-AZ, with encrypted gp3
storage (20 GiB initially, autoscaling up to 100 GiB), deletion protection and
snapshot retention on stack deletion/replacement. RDS selects the current default
minor release of major 17 and applies automatic minor upgrades.
[RDS requires two subnet AZs even for Single-AZ instances](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_VPC.WorkingWithRDSInstanceinaVPC.html).
The database stays in the first AZ with Lambda/Valkey; the second private subnet
satisfies that requirement. It does not create a standby database.

Only the website security group reaches PostgreSQL. The website uses the existing
KMS interface endpoint for encrypted configuration and a free S3 gateway endpoint
for backups. No SSM endpoint, NAT gateway or additional Lambda is provisioned.
Rotate the password by updating the SecureString, rerunning the RDS deployment
and rebuilding/deploying the website.

## Daily backups and vacuum

RDS automatic backups retain seven days, with a daily window of **07:00–07:30 UTC**.
The weekly RDS maintenance window is Sunday **08:00–08:30 UTC**. RDS snapshots and
point-in-time recovery remain the full database recovery mechanism.

At **05:00 America/New_York**, EventBridge Scheduler invokes the existing
`prod-Api-TtrekWebsite-Function` directly with this private event:

```json
{"source":"ttrek.telemetry","action":"backup-vacuum"}
```

`tcl/lambda.tcl` accepts this exact event shape separately from HTTP envelopes.
There is no public maintenance URL. IAM authorizes the scheduler to invoke the
website Lambda; no additional HTTP credential is required.

The invocation exports a consistent repeatable-read snapshot of every telemetry
table, uploads it, then runs `VACUUM (ANALYZE)` outside the snapshot transaction.
Autovacuum remains enabled throughout the day. The export is compressed JSONL at
`s3://jerily-ttrek-app/telemetry/backups/YYYY/MM/DD/...jsonl.gz`.
The bucket applies SSE-S3 encryption. UTC dates identify the backup folders.
The storage stack expires objects under `telemetry/backups/` seven days after
creation, including older backups already present when the rule is deployed.
S3 processes expiration asynchronously; this is an age-based policy, not a count
of seven files. Other bucket prefixes are unaffected.

The first JSONL record identifies format `ttrek-telemetry`, version `1`, export
time and table order. Each following record has `table` and `values`. Text stays
text, numbers stay numeric, and binary hashes use base64. A final `complete`
record contains counts for every table, including empty tables. The application
schema supplies table definitions, keys and indexes; exports contain telemetry
data, not PostgreSQL roles, extensions or other databases. Schema changes must
also update the backup format and restore implementation.

The existing TDBC PostgreSQL driver handles snapshot cursors and maintenance SQL;
tpersist supplies the table definitions and compiled, bound restore inserts.
There are no PostgreSQL command-line tools or new runtime dependencies. Cursors
fetch 256 rows at a time. A database advisory lock prevents simultaneous jobs
across website Lambda instances without serializing ordinary website requests.
Temporary exports are removed after success or failure. Only completed exports
are uploaded. Each run is limited to 300 seconds and a 400 MiB compressed file,
leaving room within Lambda's default 512 MiB temporary storage. Database
statements time out after 20 seconds and lock waits after five seconds. Revisit
these limits if data growth or observed durations approach them. Exports stop
before the final 30 seconds, reserving time for upload and vacuum.

Lambda retries failed asynchronous executions twice. Successful backups followed
by a vacuum failure may therefore produce another backup on retry. Failures log
only a phase name, never connection arguments or telemetry rows. The CloudWatch
alarm `ttrek-telemetry-maintenance-errors` observes website Lambda errors; it has
no notification recipient. Website logs retain 14 days.

The schedule follows daylight saving time. To change it:

```bash
TTREK_SCHEDULE_TIMEZONE=Europe/Nicosia \
TTREK_MAINTENANCE_SCHEDULE='cron(0 5 * * ? *)' \
  devops/infra/38-deploy-infra-rds-postgres.sh
```

## Restore

Use the application's installed Tcl runtime from a machine with access to a
fresh PostgreSQL destination. Download the chosen `.jsonl.gz` object from S3.
Create a protected target configuration with the destination `[postgres]`
settings; it may use the same tconfig encryption as production. Set
`PGSSLROOTCERT` if the destination uses a different trusted CA.

```bash
ttrek run tclsh9.1 bin/restore-telemetry.tcl backup.jsonl.gz /protected/restore-config.ini
```

The target configuration is mandatory, so the website's configuration is never
selected implicitly. Restore creates the telemetry schema if missing and refuses
to insert into nonempty tables. It validates format, table names, columns and
row counts, then restores all rows in one transaction and advances ID sequences.
The derived search snapshot is excluded from the backup table list, so existing
version 1 backups remain compatible. A successful restore invalidates its revision
in the restore transaction; the restore CLI then rebuilds it from the restored
package tables. If publication fails, the CLI reports that data was restored and
asks for `task_publish_search`. Older backups without listing flags need a registry
sync to repopulate the published catalog.
An invalid or incomplete backup rolls back the imported rows and invalidation. Treat backups as
private data and restore only trusted files.

Tail the shared function's logs:

```bash
aws logs tail /aws/lambda/prod-Api-TtrekWebsite-Function --follow \
  --profile ttrek-prod-neo --region eu-central-1
```

## Storage sizing and cost

A synthetic measurement using the actual schema on local PostgreSQL 18 found
about **45 MB per million simple events** and **70 MB per million installation
events**, including the installation index. For planning, allow **0.1 GB per
million events** for table/index overhead and growth. Dimension tables are extra:
10,000 unique environments with 1 KiB descriptions consumed about 14.6 MB,
including `environment_keys` and their indexes. Repeated identical environment
registrations reuse rows; different descriptions can add rows. Actual description
sizes, unique environments, index distribution and table bloat affect the total.
These are decimal GB, not GiB, and exclude PostgreSQL system files and WAL.

| Events/day | Event growth/month (30 days) | Event growth/year (365 days) |
| --- | --- | --- |
| 10,000 | 0.03 GB | 0.365 GB |
| 100,000 | 0.3 GB | 3.65 GB |
| 1,000,000 | 3 GB | 36.5 GB |

There is no event-retention deletion. The initial 20 GiB allocation should be
comfortable for low/moderate volume, with room reserved for WAL and database
maintenance; autoscaling can grow to 100 GiB. It does not guarantee exports will
fit the Lambda time limit at every database size. The synthetic 300,000-event,
10,000-environment fixture produced a 9.1 MB `.jsonl.gz`; real compression varies
with data entropy. Every retained backup is a full export, so S3 usage is the sum
of the compressed files within the seven-day retention window, separate from
live database storage. Retries may produce multiple files in one day.

Estimate checked against AWS public Frankfurt (`eu-central-1`) prices on
2026-11-08, at 730 hours/month, before tax, free tier and discounts:

| Added item | Monthly USD |
| --- | ---: |
| Single-AZ PostgreSQL `db.t4g.micro` at $0.019/hour | $13.87 |
| 20 GiB gp3 at $0.137/GB-month | $2.74 |
| One standard CloudWatch alarm | $0.10 |
| S3 gateway endpoint | $0.00 |
| **Additional fixed cost** | **$16.71** |

The existing Valkey micro ($10.51), KMS endpoint ($8.76), KMS key ($1.00), and
hosted zone ($0.50) bring the configured fixed baseline to **about $37.48/month**.
Removing the SSM endpoint saves **$8.76/month** versus the previous $46.24 estimate.
At 256 MiB, even 30 maintenance invocations using all 300 seconds add only about
$0.04 in Lambda compute before free tier; retries add usage. S3 Standard backup
storage is $0.0245/GB-month. Website requests, other Lambda usage, logs, builds,
transfer, storage autoscaling, excess RDS backup storage and burst CPU credits
are additional. This is a configuration estimate, not an AWS account bill.

Sources: [regional RDS prices](https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonRDS/current/eu-central-1/index.json),
[regional VPC prices](https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonVPC/current/eu-central-1/index.json),
[regional Lambda prices](https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AWSLambda/current/eu-central-1/index.json),
[regional S3 prices](https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonS3/current/eu-central-1/index.json),
and [free gateway endpoints](https://docs.aws.amazon.com/vpc/latest/privatelink/gateway-endpoints.html).

## Security

### Surface

The existing public telemetry routes accept environment registrations, download
and installation events. The scheduled maintenance entry point is accessible only through direct Lambda invocation.

### Protections

Values are bound by tpersist/TDBC. Production database connections verify TLS
certificates and hostnames. RDS storage and S3 backups are encrypted. SSM access occurs during deployment/build only; runtime S3 writes are scoped to
`telemetry/backups/`. Production configuration validation rejects plaintext
PostgreSQL and Valkey passwords. Database drivers are loaded on demand.

### Pending

Choose a notification destination for the maintenance alarm. Schedule restore exercises.
The database has one instance and no standby; backups do not provide automatic
failover. Set website concurrency with the micro instance's connection capacity
in mind: each warm Lambda interpreter owns a database connection.
