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

Tables are created transactionally on first connection. Existing LOCAL telemetry
remains in place. Environment registrations and package/platform dimensions are
shared across workers; events commit atomically. Whole transactions retry bounded
SQLite lock conflicts and PostgreSQL deadlocks/serialization failures. Schema
initialization also handles simultaneous PostgreSQL cold starts. Descriptions
are not indexed, so the registration API's 65,535-character limit does not exceed
PostgreSQL's index-entry limit. Package statistics group by both OS and architecture.

Old production Lambda SQLite files were temporary per-environment files. They are
not imported into PostgreSQL by this change.

## Deploy

Use the same AWS account/region as the website (scripts default to `eu-central-1`
and profile `ttrek-prod-neo`). The storage and keys stacks must already exist.
Nothing is deployed by editing these files.

1. **Redeploy both changed IAM policies**, using an administrator profile:
   `AWS_PROFILE=admin devops/infra/00-deploy-iam-policy.sh`.
2. Update the network: `devops/infra/20-deploy-infra-vpc0.sh`.
3. In SSM Parameter Store create **`/ttrek_sh/prod/postgres/password`** as a
   **SecureString**, encrypted with the Keys stack KMS key. Use 8–128 printable
   ASCII characters excluding spaces, `/`, `@` and double quotes. The password
   must be in the deployment region. Do not put it in tracked INI files.
4. Run `devops/infra/38-deploy-infra-rds-postgres.sh`. It builds the maintenance
   ZIP with Docker, uploads it to a content-addressed key in `jerily-ttrek-app`,
   reads the password from SSM, and deploys `Infra-DevOps-TTREK-Postgres`.
   The decrypted password goes through memory/stdin into a `NoEcho` parameter;
   it is never placed in a file, command argument or log. Python 3 and AWS CLI
   are also required. Set `TTREK_MAINTENANCE_ZIP` to an already built ZIP to skip
   Docker; `devops/package-telemetry-maintenance.sh` builds one independently.
5. Rebuild/deploy the website through its CodeBuild project. tconfig resolves
   the new PostgreSQL settings and encrypts the password into the application
   artifact. The RDS stack creates `/ttrek_sh/prod/postgres/host`, `/database`
   and `/username` String parameters automatically. Those three parameter names
   must not already be managed outside this stack.

The RDS instance is PostgreSQL 17, `db.t4g.micro`, Single-AZ, with encrypted gp3
storage (20 GiB initially, autoscaling up to 100 GiB), deletion protection and
snapshot retention on stack deletion/replacement. RDS selects the current default
minor release of major 17 and applies automatic minor upgrades.
[RDS requires two subnet AZs even for Single-AZ instances](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_VPC.WorkingWithRDSInstanceinaVPC.html).
The database stays in the first AZ with Lambda/Valkey; the second private subnet
satisfies that requirement. It does not create a standby database.

Only application and maintenance security groups reach port 5432. The maintenance
function uses a private SSM interface endpoint and an S3 gateway endpoint. There
is still no NAT or internet gateway. The additional SSM endpoint and scheduled
Lambda executions are part of this deployment.

Rotate the password by updating the SecureString, rerunning the RDS deploy script
and rebuilding/deploying the website. Maintenance reads the current SSM value on
each invocation; the website uses its encrypted build-time configuration.

## Daily backups and vacuum

The stack enables both:

- RDS automatic backups: seven days of retention, daily window **07:00–07:30 UTC**.
  The weekly RDS maintenance window is Sunday **08:00–08:30 UTC**.
- S3 logical backups: a scheduled Lambda runs PostgreSQL 17 `pg_dump --format=custom`
  daily at **05:00 America/New_York** and uploads the completed file to
  **`s3://jerily-ttrek-app/telemetry/backups/YYYY/MM/DD/…dump`**, with SSE-S3
  encryption. Date folders use UTC. S3 copies remain until explicitly removed or
  covered by a bucket lifecycle policy; this change sets no expiration.

At **06:00 America/New_York**, the same function runs `VACUUM (ANALYZE)`.
Autovacuum stays enabled throughout the day; this scheduled pass supplements it.
It does not run `VACUUM FULL` or lock the database for a full rewrite.
Schedules follow daylight saving time. Override the defaults when deploying:

```bash
TTREK_SCHEDULE_TIMEZONE=Europe/Nicosia \
TTREK_BACKUP_SCHEDULE='cron(0 5 * * ? *)' \
TTREK_VACUUM_SCHEDULE='cron(0 6 * * ? *)' \
  devops/infra/38-deploy-infra-rds-postgres.sh
```

Backup and vacuum executions are serialized. Each invocation has 15 minutes,
1 GiB memory and 10 GiB temporary storage. As telemetry grows, move backups to
longer-running compute before either the runtime or temporary storage limit is
reached. A failed dump is never uploaded. Lambda retries failed asynchronous
executions twice; backup filenames include the invocation ID. The CloudWatch
alarm `ttrek-telemetry-maintenance-errors` flags errors; no notification recipient
is configured. Logs are retained for 14 days.

These S3 files are PostgreSQL dumps, not RDS snapshot exports.
[AWS snapshot exports cannot restore an RDS instance](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_ExportSnapshot.html).
RDS snapshots support instance/point-in-time recovery; the S3 dumps support logical
restoration with PostgreSQL tools, including the schema and telemetry data:

```bash
aws s3 cp s3://jerily-ttrek-app/telemetry/backups/CHOSEN-KEY.dump telemetry.dump
# Run from a host with private database access, against a fresh destination DB.
# Supply credentials through a protected .pgpass file and verify the RDS CA.
PGSSLMODE=verify-full PGSSLROOTCERT=etc/rds-global-bundle.pem \
  pg_restore --exit-on-error --no-owner --no-acl \
  --host RESTORE-ENDPOINT --username ttrek_admin --dbname RESTORE-DATABASE telemetry.dump
```

The deployment group can tail **all `/aws/lambda/*` log groups in the account**,
including in other regions (select the region in the CLI):

```bash
aws logs tail /aws/lambda/prod-Api-TtrekWebsite-Function --follow \
  --profile ttrek-prod-neo --region eu-central-1
aws logs tail /aws/lambda/ttrek-telemetry-maintenance --follow \
  --profile ttrek-prod-neo --region eu-central-1
```

## Security

### Surface

The existing public telemetry routes accept environment registrations, download
and installation events. The maintenance function has no public trigger.

### Protections

Values are bound by tpersist/TDBC. Production database connections verify TLS
certificates and hostnames. RDS storage and S3 backups are encrypted. SSM password
access is scoped to the telemetry password; maintenance S3 writes are scoped to
`telemetry/backups/`. Production configuration validation rejects plaintext
PostgreSQL and Valkey passwords. Database drivers are loaded on demand.

### Pending

Choose a notification destination for the maintenance alarm and a backup retention
policy appropriate to the operational requirements. Schedule restore exercises.
The database has one instance and no standby; backups do not provide automatic
failover. Set website concurrency with the micro instance's connection capacity
in mind: each warm Lambda interpreter owns a database connection.
