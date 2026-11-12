# Deployment

[Documentation](readme.md) · [Project overview](../README.md)

Run these commands from the website checkout. See [setup](install.md) for
dependencies, [local development](local-development.md) for previewing changes,
and [binary distributions](releases.md) for release download configuration.

## Lambda and CodeBuild

`devops/sam-template.yaml` deploys `prod-Api-TtrekWebsite-Function` on
`provided.al2023`, with private VPC access, a scoped execution role, and 14-day
log retention. `devops/infra/40-api-gateway.json` owns the HTTP API for `/` and
`/{proxy+}` and its `https://ttrek.sh/` custom domain. SAM does not create a second
API. `Architecture` must match the native libraries in the ZIP (x86_64 by default).

The website Lambda has `ReservedConcurrentExecutions: 50`, shared by HTTP requests
and scheduled telemetry maintenance. Change this value in `devops/sam-template.yaml`
and redeploy to adjust the cap.

Production uses TLS Valkey for shared request-monitor history and global per-IP
rate limits (1000 requests per 10 seconds by default). The adapter uses API
Gateway's `requestContext.http.sourceIp`, not a caller-supplied forwarded header.
Telemetry uses tpersist with shared PostgreSQL in PROD and SQLite in LOCAL.
See [telemetry storage and maintenance](telemetry.md) for the RDS deployment,
password path, daily S3 backups and morning vacuum. Production release downloads
use the packaged `[releases]` configuration and `etc/releases.json` manifest.
The execution role can read `ttrek/*` in `ReleaseBucket`, which must match
`releases.bucket` (both default to `jerily-ttrek-app`). Binary and source requests
redirect clients to signed S3 URLs; the clients download directly from S3.
Generating these URLs does not require a Lambda network call to S3, so the
S3 gateway endpoint policy does not need release-download permissions.

Lambda, Valkey and the Single-AZ RDS instance use the first isolated subnet.
A second private subnet in another AZ satisfies RDS subnet-group requirements.
There is no NAT gateway, internet gateway,
public subnet, load balancer or Fargate service. A private KMS interface endpoint
allows tconfig to decrypt the packaged configuration at startup. The website
Lambda has no
runtime SSM access: SSM values are resolved by the build outside the VPC. The
security groups allow Lambda to reach Valkey on 6379, PostgreSQL on 5432 and KMS
on 443. The website Lambda also reaches a free S3 gateway endpoint for scheduled
JSONL backups and explicit content-image synchronization. One private scheduled
event performs backup and vacuum together. Future outbound AWS service calls
need matching endpoints and policies; calls to public third-party services would
need internet egress. API Gateway invocation and
Lambda's normal stdout/stderr logging do not need a NAT gateway.

Lambda, Valkey and the KMS endpoint use the first availability zone returned by
CloudFormation's `Fn::GetAZs`. The endpoint has one network interface. Valkey is
one `cache.t4g.micro` node without a replica or automatic failover. An outage of
that zone interrupts the website. Shared history is bounded and is not a durable
audit log.

## Infrastructure and DNS

Use the same AWS account and region for all stacks. Scripts default to
`AWS_PROFILE=ttrek-prod-neo` and `AWS_REGION=eu-central-1`; both are overridable.
Before the first deployment, use an existing administrator profile to install
the group policies described below.
For a new deployment:

1. Run `devops/infra/00-deploy-infra-keys.sh` and `10-deploy-infra-storage.sh`.
2. Run `devops/infra/20-deploy-infra-vpc0.sh`.
3. Create the SSM password described below, then run `25-deploy-infra-cache.sh`.
4. Set the SSM cache host to the cache stack's `TTrekValkeyClusterEndpointAddress` output.
5. Follow the [telemetry deployment steps](telemetry.md#deploy): create the PostgreSQL
   SecureString and deploy `38-deploy-infra-rds-postgres.sh` before building the website.
6. Run `15-deploy-infra-certificate.sh` and complete DNS validation, then run
   `45-deploy-infra-ses.sh` to create the SES exports required by the Lambda role.
   Run `16-deploy-cloudfront-cdn.sh` before the SAM application, which imports its URL.
7. Complete the GitHub connection setup below, run `30-deploy-codebuild.sh`, then
   run the build (or use the manual Lambda steps below).
8. Once Lambda exists and the certificate is issued, run `40-deploy-api-gateway.sh`.

When updating an existing deployment, redeploy the changed IAM policies first,
then `20-deploy-infra-vpc0.sh`, then the new RDS stack. The network update adds a
second private subnet and route-table export while retaining the first subnet,
Lambda/Valkey security-group exports and the one-interface KMS endpoint.

The keys template creates the customer-managed key used by tconfig and the SSM
password. Key rotation is enabled. `DeletionPolicy` and `UpdateReplacePolicy`
retain the key, since deleting it would make existing encrypted configuration
unreadable. The S3 bucket is also retained, blocks public access, and uses SSE-S3.
Its lifecycle rule expires `telemetry/backups/` objects after seven days. Redeploy
the IAM policies and `10-deploy-infra-storage.sh` to apply this rule to an existing
bucket. Release binaries and other artifact prefixes are unaffected.
The template retains the deployed `AccessControl: Private` declaration because
removing it can trigger a rejected ACL update on the existing ACL-disabled bucket.
This preserves the declaration without enabling ACLs or granting public access.
The Lambda runtime gets only `kms:Decrypt` on this key; the build gets
`kms:Encrypt`/`kms:Decrypt` and `ssm:GetParameter` under `/ttrek_sh/prod/`.

`15-infra-certificate.yml` requests an ACM public certificate for `ttrek.sh` using
DNS validation in the API's region. No personal name, email or country is needed.
Both deployment scripts automatically find the matching public Route 53 zone in
the selected account using `route53:ListHostedZones`. For subdomains, the most
specific matching zone is selected; private zones are ignored. Duplicate public
zones require `TTREK_HOSTED_ZONE_ID=Z...` to select one explicitly. ACM then adds
the validation record, and the API stack adds an apex A alias.
The lookup uses Tcl 8.6+ and the AWS CLI, with no application packages required;
set `TCLSH` to select a specific interpreter.

CloudFormation's DNS record resource supports zone names, but ACM validation
requires a zone ID. The scripts resolve it before deployment, avoiding a custom
Lambda resource just for the lookup. Direct CloudFormation deployments still
need the `HostedZoneId` parameter for automatic DNS configuration.

If there is no matching public zone, or you explicitly set
`TTREK_HOSTED_ZONE_ID=''` to skip lookup, add ACM's validation CNAME at your DNS provider while the
certificate stack waits, then point the apex to the API stack's
`RegionalDomainName` output using your provider's ALIAS/ANAME or CNAME-flattening
feature. A normal CNAME cannot be used at the zone apex. Keep ACM's validation
record for renewal. Do not use a fixed IP address for API Gateway.

The API imports `Infra-DevOps-TTREK-Certificate-CertificateArn` by default.
`TTREK_CERTIFICATE_ARN` can select an already issued certificate in the same
region instead. The certificate must cover `ttrek.sh` itself. Existing custom
domains/DNS records must be migrated or imported before creating resources with
the same names; these templates do not take over unmanaged resources.
See [ACM CloudFormation DNS validation](https://docs.aws.amazon.com/AWSCloudFormation/latest/TemplateReference/aws-resource-certificatemanager-certificate.html)
and [HTTP API custom domains](https://docs.aws.amazon.com/apigateway/latest/developerguide/http-api-custom-domain-names.html).

### Transactional email (SES)

`devops/infra/45-infra-ses.yml` manages the `ttrek.sh` sending identity in the
selected region and its default `ttrek-transactional` configuration set. It
enables 2048-bit Easy DKIM, reputation metrics, and suppression of addresses
that bounce or complain. The dedicated MAIL FROM domain is `bounce.ttrek.sh`.
Route 53 receives three DKIM CNAME records and the MAIL FROM MX/SPF records;
the apex MX and SPF records are unaffected. This provisions sending, not an inbox.

Update the [deployment IAM policies](#deployment-iam-policy), then deploy this
stack before deploying the SAM template:

```bash
devops/infra/45-deploy-infra-ses.sh
```

The defaults are `AWS_PROFILE=ttrek-prod-neo`, `AWS_REGION=eu-central-1`, and
stack `Infra-DevOps-TTREK-SES`. The script uses the same hosted-zone resolver as
the certificate and API scripts. `TTREK_HOSTED_ZONE_ID=''` skips Route 53
management; publish the stack's `DkimRecordName1`/`DkimRecordValue1` through
`DkimRecordName3`/`DkimRecordValue3` as CNAMEs, and `MailFromMxValue`/`MailFromSpfValue`
as MX/TXT records at `MailFromDomain`, at your DNS provider. Keep DKIM records
unproxied. Direct CloudFormation deployments accept the equivalent parameters.

| Environment variable | Template parameter | Default |
| --- | --- | --- |
| `TTREK_DOMAIN_NAME` | `DomainName` | `ttrek.sh` |
| `TTREK_HOSTED_ZONE_ID` | `HostedZoneId` | Public-zone lookup |
| `TTREK_SES_MAIL_FROM_SUBDOMAIN` | `MailFromSubdomain` | `bounce` |
| `TTREK_SES_CONFIGURATION_SET` | `ConfigurationSetName` | `ttrek-transactional` |
| `TTREK_SES_MANAGE_DMARC` | `ManageDmarcRecord` | `false` |
| `TTREK_SES_DMARC_POLICY` | `DmarcPolicy` | `none` |

DMARC is opt-in because `_dmarc.ttrek.sh` applies to every sender for the domain.
If no record exists and this stack should own it, use
`TTREK_SES_MANAGE_DMARC=true`; the default policy requests no quarantine or
rejection. For external DNS, this option exposes the DMARC record name/value
as outputs instead. Keep an existing DMARC policy under its current management.
Before deploying, reconcile any existing SES identity/configuration set or
conflicting DNS records; the stack does not take over unmanaged resources.
Deployment-policy ARNs and DNS restrictions use the defaults above; adjust them
when selecting another domain, configuration set or MAIL FROM subdomain.

Stack completion does not mean DNS verification has finished. Inspect the
identity in the same region:

```bash
aws sesv2 get-email-identity --email-identity ttrek.sh \
  --region "${AWS_REGION:-${AWS_DEFAULT_REGION:-eu-central-1}}" \
  --profile "${AWS_PROFILE:-ttrek-prod-neo}" \
  --query '{Verified:VerifiedForSendingStatus,DKIM:DkimAttributes.Status,MailFrom:MailFromAttributes.MailFromDomainStatus}'
```

Wait for `Verified=true`, `DKIM=SUCCESS`, and `MailFrom=SUCCESS`. The identity uses
`REJECT_MESSAGE` on MAIL FROM MX failure, so it will reject sends while that
verification is pending or failing. SES sandbox/production access is regional
and is managed separately from this stack. In the sandbox, use verified
recipients or `success@simulator.amazonses.com`; request production access before
sending to arbitrary recipients. See [SES domain verification](https://docs.aws.amazon.com/AWSCloudFormation/latest/TemplateReference/aws-resource-ses-emailidentity.html),
[custom MAIL FROM](https://docs.aws.amazon.com/ses/latest/dg/mail-from.html), and
[production access](https://docs.aws.amazon.com/ses/latest/dg/request-production-access.html).

The template exports `IdentityArn`, `ConfigurationSetName`, and
`ConfigurationSetArn` under `Infra-DevOps-TTREK-SES-*`. The new Tcl extension can
use the verified identity with `region eu-central-1`, a `from` address at
`ttrek.sh`, and `configuration_set ttrek-transactional`. Install
`aws-sdk-tcl-ses` and use `package require awsses 1.0.16` in the sending application.
Feedback forwarding remains enabled; use a monitored From or `return_path`
mailbox for bounce/complaint notifications. Reputation metrics incur CloudWatch
charges; application event destinations can be added separately.

`devops/sam-template.yaml` grants the website Lambda execution role
`ses:SendEmail`, `ses:SendRawEmail`, and `ses:SendTemplatedEmail`, scoped to the
exported identity and configuration set. Deploy the SES stack before creating
or updating the SAM stack, which imports those ARNs. The deployment policies
manage SES resources and read their status; the application role owns sending.
The current isolated VPC still needs an SES **API** interface endpoint on TCP 443
with private DNS and security-group access from Lambda, or outbound internet
access. An SMTP endpoint cannot serve `awsses` API requests. This identity stack
does not change the VPC. See [SES VPC endpoints](https://docs.aws.amazon.com/ses/latest/dg/send-email-set-up-vpc-endpoints.html).

### Deployment IAM policy

The existing IAM group `ttrek_prod_admin_group` receives two customer managed
policies: `00-iam-policy-deploy.json` covers deployment commands, DNS, SSM, log
reads and maintenance resources; `00-iam-policy-resources.json` covers the
remaining CloudFormation resource operations.
Both files live in `devops/infra`. Before `00-deploy-infra-keys.sh`, run:

```bash
AWS_PROFILE=admin devops/infra/00-deploy-iam-policy.sh --dry-run
AWS_PROFILE=admin devops/infra/00-deploy-iam-policy.sh
```

Replace `admin` with an administrator profile in the deployment account. The
script resolves its account ID with STS, substitutes the selected region, and
deploys `Infra-DevOps-TTREK-Permissions`. CloudFormation creates or updates
`TTrekInfrastructureDeploy` and `TTrekInfrastructureResources` and attaches them
to the group. It manages policy versions on subsequent updates. The administrator
needs CloudFormation deployment and IAM managed-policy/attachment permissions.
The group must already exist; the script does not create it.

After deployment, the script verifies both attachments and removes the old
`TTrekInfrastructureDeploy` inline policy if present. This migration also needs
`iam:ListAttachedGroupPolicies`, `iam:ListGroupPolicies` and `iam:DeleteGroupPolicy`.
Other group policies are preserved. `--dry-run` prints the complete rendered
CloudFormation template without changing AWS. The source JSON contains
placeholders and must be rendered before it is submitted to IAM.

The policies cover the application infrastructure scripts (Keys through SES): stack change
sets, KMS keys and aliases, the S3 bucket, isolated VPC, Valkey, ACM/DNS, CodeBuild
and its role, CloudFront distribution/cache/OAC resources, and the public API's
Lambda invocation permission. CloudFront permissions are split between the two
managed policies to keep both within IAM's size limit. Most resource
operations require CloudFormation's [forward access session](https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/fas-requests-and-permission-evaluation.html).
SSM reads and decryption through SSM are scoped to `/ttrek_sh/*`;
DNS changes are limited to A/CNAME records at `ttrek.sh` and `_*.ttrek.sh`,
DKIM CNAMEs at `*._domainkey.ttrek.sh`, MAIL FROM MX/TXT records at
`bounce.ttrek.sh`, and the optional TXT record at `_dmarc.ttrek.sh`.
SES management is scoped to the `ttrek.sh` identity and `ttrek-transactional`
configuration set through CloudFormation, with direct read access for status checks.
Role passing is scoped to CodeBuild and the telemetry scheduler. Cleanup permissions
for the removed maintenance Lambda are retained for existing stack upgrades.
The policies also cover RDS and its service-linked role, maintenance schedules,
alarms and cleanup of the former stack-owned PostgreSQL parameters. Both
policy files changed for telemetry and must be redeployed. Direct log reads allow
`aws logs tail /aws/lambda/prod-Api-TtrekWebsite-Function --follow`, and other
`/aws/lambda/*` groups in the account.

These are infrastructure administrator policies: they use broader regional access
through CloudFormation for generated EC2, KMS, ACM and cache resource IDs, and
the deployer can edit the build role's inline permissions. These policies are not
permissions boundaries. Their fixed names match the templates' defaults; adjust them when changing
the application, bucket, domain or Lambda name. Manual SSM writes, GitHub connection
setup, starting builds, and manual SAM deployments need separate permissions.
Stacks must use the caller's credentials, as the supplied scripts do; an existing
CloudFormation service role needs its own resource permissions.

IAM's [5,120-character inline group limit is cumulative](https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_iam-quotas.html),
so multiple inline policies would still hit it. Each managed policy has its own
6,144-character limit; the script checks both documents before deployment.
The two attachments use two of the group's ten managed-policy slots.

## Production and local configuration

You manage the SSM passwords, cache endpoint, and PostgreSQL host, database and
username String parameters. Copy PostgreSQL values from the RDS stack outputs.
`devops/config.prod.ini` is a secret-free input template. tconfig resolves
`/ttrek_sh/prod/<section>/<key>` and encrypts SecureString values into the generated
`build/prod/config.ini`. That generated file is copied to `etc/config.ini` inside
the Lambda ZIP. The build fails if the password is missing, is not encrypted, or
the cache endpoint is missing. No plaintext secret is committed or printed.

| SSM parameter | Type | Value |
| --- | --- | --- |
| `/ttrek_sh/prod/postgres/password` | SecureString | Required; see [telemetry deployment](telemetry.md#deploy) |
| `/ttrek_sh/prod/postgres/host` | String | Operator-managed: RDS endpoint output |
| `/ttrek_sh/prod/postgres/database` | String | Operator-managed: `ttrek_telemetry` |
| `/ttrek_sh/prod/postgres/username` | String | Operator-managed: `ttrek_admin` |
| `/ttrek_sh/prod/redis/password` | SecureString | Required; 16–128 characters, encrypted with the Keys stack KMS key |
| `/ttrek_sh/prod/redis/host` | String | Required; cache primary endpoint from stack outputs |
| `/ttrek_sh/prod/redis/port` | String | Optional; default `6379` |
| `/ttrek_sh/prod/redis/username` | String | Optional; must match the cache user, currently `appuser` |
| `/ttrek_sh/prod/redis/ssl_ca_file` | String | Optional; AL2023 default `/etc/pki/tls/certs/ca-bundle.crt` |
| `/ttrek_sh/prod/ratelimit/window_millis` | String | Optional; default `10000` |
| `/ttrek_sh/prod/ratelimit/limit` | String | Optional; default `1000` |
| `/ttrek_sh/prod/request_monitor/history_max_events` | String | Optional; default `100000` |
| `/ttrek_sh/prod/request_monitor/master_template` | String | Optional; default `request-monitor-master.html.jinja` from `www/` |
| `/ttrek_sh/prod/request_monitor/store` | String | Optional; only `valkey` is supported |

The Valkey user group contains only the password-authenticated `appuser`.
Valkey requires password or IAM authentication for each user and disables the
built-in `default` user when this group is attached. A separate disabled default
user with `no-password-required` is unsupported and unnecessary; see
[Valkey RBAC](https://docs.aws.amazon.com/AmazonElastiCache/latest/dg/Clusters.RBAC.html).

The cache deployment script reads that same password with decryption into a pipe,
validates it in memory, and supplies the `NoEcho` CloudFormation parameter through
`file:///dev/stdin`. It does not put the password in temporary files, command
arguments or an environment variable. Do not run secret-handling commands with
AWS CLI debug logging. Updating SSM alone does not update a running deployment:
password rotation requires a coordinated cache update and Lambda rebuild/deployment.

The Snap AWS CLI launcher can report `Exception ignored while flushing sys.stdout:
OSError: [Errno 9] Bad file descriptor` when stdout is redirected to a regular
file. This was reproducible with `aws --version > file`, without an AWS request.
The cache script uses pipes for AWS CLI input/output and forwards deployment
output through Python, avoiding that failure while preserving command exit codes.

For local Lambda mocks, copy `etc/config.local.ini.example` to the ignored
`etc/config.local.ini`. `TTREK_LOCAL_CONFIG` can select another local file.
The mocks read it from the host; it is never packaged. Local request monitoring
uses Valkey shared across workers; local Lambda rate limiting remains in memory
per worker. The local INI must supply `[redis]` settings for a running service;
the launcher fails if the section is missing.
Local mode ignores any packaged production configuration and makes no SSM/KMS
calls. Direct server development still uses its existing Valkey configuration.

## CodeBuild

CodeBuild reads `devops/buildspec.yml`, selected by `Source.BuildSpec` in
`devops/infra/30-codebuild.yml`. The AL2023 x86_64 build image targets Lambda's
OS and architecture. Before running ttrek, the install phase installs GCC/G++,
Make, Bash, curl, Git, patch, pkg-config, Perl, tar, gzip and CA certificates,
plus ZIP and binary utilities for packaging. It installs CMake (`>=3.25,<5`)
and SAM with pip, then checks the CMake and compiler versions. These tools are
needed to build the site's dependencies even though ttrek itself is downloaded.
The build:

1. Downloads the ttrek 1.2.0 Linux AMD64 glibc binary from
   `s3://jerily-ttrek-app/ttrek/1.2.0/linux-amd64-glibc/ttrek`, makes it executable,
   and checks that it starts with `ttrek self-update -version`.
2. Uses that binary to install from the private registry (build tools) and the
   pinned public `registry` submodule (runtime recipes).
3. Restores retained browser assets, builds browser assets, then the
   application and asset checks.
4. Generates encrypted production config from SSM, packages with tdevops using
   `--local-only`, and sets executable ZIP attributes. This skips the numeric
   glibc cutoff that rejects AL2023's backported symbols; architecture,
   dependency resolution, and staged-site checks still run.
5. Validates the SAM template and packaged image settings/bytes, preserves the
   new asset fingerprints, and deploys `devops/sam-template.yaml` with SAM.
   When CDN delivery is enabled, browser assets are uploaded before SAM deployment.
   Content images are uploaded by the explicit `task_sync_website` patch task.

Content images use `[content_images]` in `devops/config.prod.ini`, which is carried
into the generated production config. After deploying content changes, run the
[explicit sync patch task](#explicit-website-patch-tasks). It uses the website
Lambda role to upload missing or changed wiki and blog images before committing their
database references. Validation or upload errors fail the task and roll back
its database changes. Keys preserve paths under `<prefix>/docs/` and
`<prefix>/blog/`. SHA-256 comparisons skip unchanged bytes; changes replace the
same key. S3 replacements are independent of the SQL transaction. Each response
uses signed S3 URLs or CloudFront paths according to the production setting.
Production startup and HTTP requests make no S3 listing or upload calls for
images. Local workers still upload missing images to their configured bucket or
local S3 mock. `task_initdb_website` initializes schemas only.

Before relying on patch-task uploads, update the S3 gateway endpoint policy with
`bash devops/infra/38-deploy-infra-rds-postgres.sh`. It allows `s3:ListBucket`, `s3:GetObject` and
`s3:PutObject` only for the configured image prefix, alongside existing backup
writes. The SAM Lambda role already grants the corresponding image permissions;
the [endpoint policy](https://docs.aws.amazon.com/vpc/latest/privatelink/vpc-endpoints-s3.html#edit-vpc-endpoint-policy-s3)
must also allow these calls.
Deploying the website does not run the sync task automatically.

The defaults use bucket `jerily-ttrek-app`, region `eu-central-1`, prefix
`ttrek/content/images`, `docs_directory=content/docs`, and `blog_directory=content/blog`. If changing the bucket or
prefix, keep the PostgreSQL stack's endpoint and SAM
`ContentImagesBucket`/`ContentImagesPrefix` parameters aligned with the generated
production configuration (including any SSM overrides). Production image
directories must be included under `content/`
in the Lambda archive. The build checks their paths and bytes against the
checkout; the patch task uploads images from the deployed archive.

### Content image CDN

Deploy `devops/infra/16-infra-cloudfront-cdn.yml` with
`bash devops/infra/16-deploy-cloudfront-cdn.sh` after updating the deployment IAM
policies. This creates `Infra-DevOps-TTREK-CloudFrontCDN` using the existing image
bucket. `CONTENT_IMAGES_BUCKET`, `CONTENT_IMAGES_PREFIX`, and
`BROWSER_ASSETS_PREFIX` (default `cdn`) override the defaults in the CDN and
CodeBuild deploy scripts; keep them aligned with `content_images.bucket`,
`content_images.prefix`, and `content_images.assets_prefix` in the configuration.
The stack owns the bucket policy; merge any separately managed statements before
adopting it for a bucket with an existing policy.

The distribution uses the default HTTPS CloudFront hostname and an
[origin access control](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/private-content-restricting-access-to-s3.html).
Its bucket policy grants this distribution only `GetObject` for
`<prefix>/blog/*`, `<prefix>/docs/*`, and `<assets_prefix>/*` (default `cdn/*`).
It cannot serve release archives, backups or other bucket objects. Viewers can read
these files through CloudFront; S3 remains private.
The full S3 key is also the URL path, for example:
`https://<distribution>.cloudfront.net/ttrek/content/images/blog/images/example.png`.

`CdnBaseUrl` exports `${AWS::StackName}-BaseUrl`. SAM's `CloudFrontStackName`
parameter selects that export (default `Infra-DevOps-TTREK-CloudFrontCDN`) and
injects it as `CONTENT_IMAGES_CLOUDFRONT_URL`. Deploy the CDN stack before the SAM
stack, including when CDN delivery is disabled. Delivery is enabled in
`devops/config.prod.ini` with:

```ini
[content_images]
cloudfront_enabled=true
assets_prefix=cdn
```

Set it to `false` for signed S3 image URLs and the existing local CSS/JS/favicon
URLs. LOCAL always retains that behavior. Changing
this setting requires a configuration deployment but no content resync; both URL
modes use the same stored paths. Direct PROD servers must supply the same environment
variable when enabled. Upload and packaging helpers do not need a distribution URL.

`devops/upload-browser-assets.tcl` reads the exact generated production config and
uploads CSS/JS from the versioned asset tree, adjacent license notices, both
favicon formats, and the installed `treqmon` chart script. CodeBuild runs it after
artifact validation and before SAM deployment. It skips uploads when the flag is
false and fails the build on missing assets or S3 errors. Unchanged fingerprinted
objects are reused; fixed paths are refreshed. Removed and older versioned assets
are retained. Manual builds can run:

```bash
ttrek run tclsh9.1 devops/upload-browser-assets.tcl build/prod/config.ini
```

Redeploy `30-deploy-codebuild.sh` to grant uploads under `cdn/*` (or the configured
browser prefix), and redeploy the CDN stack to grant read access. No runtime S3
uploads are needed for browser assets. The application adds only the imported CDN
origin to the script/style/image CSP directives on package-rendered HTML.

Browser cache behaviors use [CloudFront response-header policies](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/modifying-response-headers.html)
with CORS for JavaScript modules and `nosniff`. Stable paths revalidate in the
browser; fingerprinted CSS/JS keep one-year immutable caching. The stack exports
`${AWS::StackName}-BrowserAssetResponseHeadersPolicyId` and
`${AWS::StackName}-VersionedAssetResponseHeadersPolicyId` for other stacks to
import and attach to their own cache behaviors. These are policy IDs; Lambda's
page CSP uses the exported base URL instead.

Images, favicons, license files and the monitor script use a five-minute maximum edge TTL by default (`ImageCacheTTL`, or
`CONTENT_IMAGES_CACHE_TTL` in the deploy script), with browser revalidation.
Changed images can remain cached at the edge until that TTL expires. For immediate
refresh, invalidate the changed CloudFront paths using an authorized operator.
Sync does not add content hashes to image URLs or automatically invalidate the CDN.
Run `task_sync_website` after deploying the path-based image packages to publish
the new locations and stored references; there is no legacy-key fallback.

Fingerprint history lives under `s3://$SAM_ARTIFACT_BUCKET/lambda/ttrek-sh-assets/`.
CodeBuild downloads this directory before building and uploads it after successful
validation, using its existing `lambda/*` S3 permissions. Every archive includes
the retained files, allowing older open pages to request their assets after a
deployment. Neither sync uses `--delete`. Do not apply a lifecycle expiration to
this prefix without an explicit retention policy; old pages can outlive the HTML
cache. History increases archive size over time, so monitor Lambda package limits.
This S3 prefix remains build storage. When CDN delivery is enabled, the validated
files are also published under `cdn/` in the image bucket. Otherwise production
assets continue to come from Lambda.

The rebuilt binary targets glibc 2.28 with static third-party dependencies;
[AL2023 provides glibc 2.34](https://docs.aws.amazon.com/linux/al2023/ug/core-glibc.html).
The CodeBuild role's existing `s3:GetObject` permission on
`arn:aws:s3:::jerily-ttrek-app/ttrek/*` covers this artifact.
The site's native dependencies are built with AL2023's compilers for Lambda.

CodeBuild checks out `PrivateRegistry` as a secondary source. Its GitHub
credentials must permit access to `private-ttrek-registry`, `tdevops` and the
mock-tool source repositories. The build enables CodeBuild's Git credential
helper for private recipe downloads. `PrivateRegistryRef` selects the registry
branch/tag/commit. Node/npm are supplied by the build image, and SAM is installed
as a build tool. Neither is a ttrek dependency.

The install command uses `-fail-verbose` so CodeBuild prints the failing recipe's
log, including Git's error for a failed clone. The `Failed command` line alone
does not identify whether the failure is authentication, repository access, or
another Git error.

To authenticate the private registry, install AWS Connector for GitHub on the
personal account `jerily`. Authorizing the app to identify your GitHub account
does not install it or grant repository access:

1. Open [AWS Connector for GitHub in the Marketplace](https://github.com/marketplace/aws-connector-for-github).
2. Click **Add**, then **Install it for free** if prompted.
3. Select the personal GitHub account **jerily**.
4. Choose **Only select repositories** and include `ttrek.sh`,
   `private-ttrek-registry`, `tdevops`, `mock-lambda-app`, `mock-proxy-app`, and
   `mock-s3-app`, plus any other private repositories referenced by build recipes.
5. Click **Install**. The app appears under **Installed GitHub Apps**, where you
   can manage repository access.
6. Return to the AWS connection wizard in the build's region (`eu-central-1`
   by default), select that installation, and complete the connection. Its
   status must be **Available**.

Export the resulting connection ARN, then deploy the build stack:

```bash
export TTREK_GITHUB_CONNECTION_ARN='arn:aws:codeconnections:eu-central-1:ACCOUNT_ID:connection/CONNECTION_ID'
devops/infra/30-deploy-codebuild.sh
```

The script stops before calling AWS if `TTREK_GITHUB_CONNECTION_ARN` is unset or
empty, prints the installation instructions, and otherwise passes the ARN as
the `GitHubConnectionArn` template parameter. The template registers that
connection as CodeBuild's regional default GitHub credential through
`GitHubSourceCredential` and grants the build role
`codeconnections:GetConnection` and `codeconnections:GetConnectionToken`
for that ARN. The build role also has `s3:GetObject` on
`arn:aws:s3:::jerily-ttrek-app/ttrek/*` to download published ttrek binaries.
The ttrek source checkout and `TtrekRef` parameter are no longer needed.
Both project sources deliberately omit `Auth` so they use the regional default.
Setting `Auth.Type: CODECONNECTIONS` on individual sources overrides that default
with credentials scoped to those repositories; recipe clones of other private
repositories can then fail with `GITHUB Git credential unavailable` even when
the default credential is registered. Git's subsequent `could not read Username`
message does not mean a GitHub username must be supplied.

To inspect the registered default without displaying an access token:

```bash
aws codebuild list-source-credentials \
  --region eu-central-1 --profile ttrek-prod-neo
```

The `GITHUB` entry must use `CODECONNECTIONS` and reference the connection ARN
passed to the stack. The deployment caller needs permission to manage CodeBuild
source credentials; the repository's deployment group policies do not include
that setup permission. Registering the default affects CodeBuild projects across
the account in that region. The enabled `env.git-credential-helper: yes` supplies
credentials to recipe Git clones; no token belongs in `ttrek.json`, a clone URL,
or the build log.
See [AWS's GitHub App connection instructions](https://docs.aws.amazon.com/codebuild/latest/userguide/connections-github-app.html)
and [source credential selection](https://docs.aws.amazon.com/codebuild/latest/userguide/multiple-access-tokens.html).

Run `devops/infra/30-deploy-codebuild.sh` again to apply the source, image,
permissions and environment changes. `LambdaStackName` and `LambdaFunctionName`
select deployment targets. The existing `${S3Prefix}-${AppName}` bucket stores
SAM artifacts. CodeBuild deploys only after all build commands succeed; it no
longer publishes ECR images or updates ECS.

The build role has `lambda:PutFunctionConcurrency`, `lambda:GetFunctionConcurrency`
and `lambda:DeleteFunctionConcurrency` permissions scoped to the website function
ARN, covering deployment, inspection and rollback of the concurrency setting.
Apply `devops/infra/30-deploy-codebuild.sh` before deploying the Lambda concurrency
cap so CloudFormation can manage it using the updated build role.

The build role's Put/Get/DeleteFunctionEventInvokeConfig permissions cover both
the function ARN and its `:$LATEST` qualifier, which SAM uses for asynchronous
invocation settings. Apply the CodeBuild stack update before retrying a Lambda
deployment or rollback that failed on these actions.

For a manual deployment from an AL2023 build host with dependencies installed:

```bash
export AWS_PROFILE=ttrek-prod-neo AWS_REGION=eu-central-1
mkdir -p public/assets/versioned
aws s3 sync s3://jerily-ttrek-app/lambda/ttrek-sh-assets/ public/assets/versioned/ --only-show-errors
ttrek run -script build-assets
npm test
export TTREK_CONFIG_KMS_KEY=$(aws cloudformation describe-stacks \
  --stack-name Infra-DevOps-TTREK-Keys \
  --query 'Stacks[0].Outputs[?OutputKey==`TTrekKMSMasterKeyArn`].OutputValue | [0]' --output text)
bash devops/generate-prod-config.sh
TTREK_PRODUCTION_CONFIG="$PWD/build/prod/config.ini" ttrek run -script package-lambda -- --local-only
python3 devops/finalize-lambda.py dist/ttrek-sh.zip
sam validate --lint --template-file devops/sam-template.yaml
aws s3 sync public/assets/versioned/ s3://jerily-ttrek-app/lambda/ttrek-sh-assets/ --only-show-errors
sam deploy --template-file devops/sam-template.yaml \
  --stack-name Infra-DevOps-TTREK-Lambda \
  --s3-bucket jerily-ttrek-app --s3-prefix lambda/ttrek-sh \
  --capabilities CAPABILITY_NAMED_IAM \
  --region eu-central-1 --profile ttrek-prod-neo
```

Build deployment packages and their native dependencies on AL2023 for the target
Lambda architecture. Here `--local-only` bypasses the glibc version check; it
does not change the production configuration or prevent deployment. Compatibility
with the Lambda runtime is not verified by this packaging step.
`finalize-lambda.py` requires the production configuration and release manifest,
and sets the executable ZIP attributes for `bootstrap` and `local/bin/tclsh`.
CodeBuild then checks that the packaged configuration loads the exact checkout
manifest before deploying. The packaging file list explicitly includes
`etc/releases.json`; staged validation catches missing or invalid checksum files.

## Updating an existing deployment

The API stack and Lambda stack now have separate ownership. Updating an older
SAM stack removes its generated API and replaces the function when renaming it.
Plan the cutover and perform the first migration using an administrative deployment
role that can also remove the old `ttrek-sh` function, role and log group; the new
CodeBuild role is scoped to `prod-Api-TtrekWebsite-Function`. An already existing
function with that name must be imported or otherwise reconciled before deployment.

Retire the old Fargate stack before applying the VPC changes: it imports the public
subnet export being removed. The VPC stack retains its name
`Infra-DevOps-TTREK-Base` and existing private subnet/cache security-group exports.
The storage template no longer creates ECR. If an old repository contains images
you need, apply a retain policy or migrate it before updating the storage stack.
The old Fargate template and launcher have been removed. No deployment script
automatically deletes stacks or migrates existing resources/data.

If the bucket or repository still belongs to the original combined Base stack,
use CloudFormation resource refactoring or retain/import before applying split
templates. The cache now enables encryption at rest; review the change set for
replacement and preserve needed cache data before updating an existing cache.

## API Gateway template

```sh
ttrek install -force -registry ../private-ttrek-registry -add-pubreg tdevops mock-proxy-app
python3 devops/generate-api-gateway.py
```

The site generator calls tdevops with `etc/routes.json`, selected by `routes` in
`etc/tdevops.tcl`. It removes the shared generator's optional authorizer and sets
every route to `AuthorizationType: NONE`. The website has no authorizer parameter,
resource or permission. Deployment defaults live under `apiGateway`; the template
exposes API name, stage, timeout and backend function parameters.

The generator preserves the deployed logical IDs and the domain, certificate,
mapping, DNS and related outputs maintained in `devops/infra/40-api-gateway.json`.
It writes the complete result to `dist/api-gateway.json` and copies it to that
tracked template. Review the diff before deploying with `40-deploy-api-gateway.sh`.
The local mock ignores deployment settings. Generation does not deploy AWS resources.

## Existing apex A record blocks API deployment

`SiteDns` creates an A alias for `ttrek.sh` only when `HostedZoneId` is nonempty.
Removing `SiteDns` from the template does not add or update DNS. Deleting a
conflicting record in Route 53, leaving `SiteDns` in the template, and successfully
redeploying creates the new API Gateway alias; deletion can leave a DNS gap.

To preserve an existing record during deployment:

1. If `Infra-DevOps-TTREK-Api` is in `ROLLBACK_COMPLETE`, delete that failed stack
   first using the CloudFormation console or an administrator profile. A failed
   initial creation in that state cannot be updated. Do not delete the existing
   Route 53 record as part of this cleanup.
2. Run `TTREK_HOSTED_ZONE_ID='' devops/infra/40-deploy-api-gateway.sh` to deploy
   the API and custom domain without managing DNS.
3. Once the API is ready, edit the existing apex A record in Route 53 to an alias
   using the stack's `RegionalDomainName` and `RegionalHostedZoneId` outputs,
   with `EvaluateTargetHealth=false`. Preserve its previous value for rollback.
4. Continue passing `TTREK_HOSTED_ZONE_ID=''` on subsequent API deployments while
   DNS is managed separately. No template edit is required.

The generic error's import suggestion does not mean Route 53 RecordSet supports
CloudFormation import: it is absent from AWS's
[import-supported resource list](https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/resource-import-supported-resources.html).
Do not attempt to import the entire hosted zone just to resolve this record conflict.

API Gateway's `TagResource` API uses HTTP-verb IAM actions:
[`apigateway:POST` for HTTP/WebSocket APIs](https://docs.aws.amazon.com/apigatewayv2/latest/api-reference/tags-resource-arn.html)
and [`apigateway:PUT` for REST APIs](https://docs.aws.amazon.com/apigateway/latest/api/API_TagResource.html).
The deploy policy permits both on `/tags/*`. The resource policy also includes
`apigateway:TagResource` because the API stack's actual `ApiStage` failure reported
an explicit authorization denial for that action on `/apis/.../stages`. Retain
that permission alongside the documented HTTP-verb permissions. Some IAM linters
may not recognize the action because it is absent from the published action list.

## Explicit website patch tasks

The existing website Lambda accepts private direct invocations with
`{"source":"ttrek.patch","task":"task_initdb_website"}` or
`{"source":"ttrek.patch","task":"task_sync_website"}`. The first initializes the
installed packages' schemas; the second synchronizes wiki/blog content, images,
and registry metadata, then publishes both search indexes in the same transaction.
`{"source":"ttrek.patch","task":"task_publish_search"}` republishes search from
the stored package tables without importing recipes or content. HTTP request
envelopes cannot select these tasks. IAM
`lambda:InvokeFunction` authorizes the whole function, including its existing
backup task; IAM does not restrict individual task names.

`devops/infra/31-codebuild-patch.yml` defines the new, independent
`Infra-DevOps-TTREK-Patch` CodeBuild project. It needs only Lambda invocation and
its own log permissions; the Lambda uses its existing VPC/database access.
The website deployment build does not invoke it. Redeploy the group policies with
`00-deploy-iam-policy.sh` using an administrator profile to allow management of
the new project, role and log group. Deploy the patch stack separately with its
companion script, then select the task when starting a build:

```sh
bash devops/infra/31-deploy-codebuild-patch.sh
aws codebuild start-build --project-name Infra-DevOps-TTREK-Patch \
  --environment-variables-override name=PATCH_TASK,value=task_initdb_website,type=PLAINTEXT
aws codebuild start-build --project-name Infra-DevOps-TTREK-Patch \
  --environment-variables-override name=PATCH_TASK,value=task_sync_website,type=PLAINTEXT
# Republish directly edited/restored database metadata without importing recipes:
aws codebuild start-build --project-name Infra-DevOps-TTREK-Patch \
  --environment-variables-override name=PATCH_TASK,value=task_publish_search,type=PLAINTEXT
```

The script uses the standard AWS profile/region defaults above.
`TTREK_WEBSITE_FUNCTION_NAME` overrides the target Lambda and `TTREK_PATCH_TASK`
sets the project's default task (otherwise `task_sync_website`). Deploying the
stack does not start a build or run a task.

Run initialization before the first sync on a new database. Initialization creates
missing tables/indexes and applies additive schema upgrades; repeated runs preserve
existing content, registry IDs, and telemetry. It does not drop or clear tables or
import content.

When upgrading an existing site from Markdown snapshots to database-backed content,
run both tasks in order once: `task_initdb_website`, then `task_sync_website`.
The new content tables start empty even though the Markdown files already exist.
After that first import, rerunning initialization does not require another sync;
sync again when publishing content, images, or registry metadata changes.

The tags/database-catalog upgrade also requires both tasks once. It adds `tags`
and `listed` to existing package rows; `listed` starts at `0`, and the website
only displays rows with `listed = 1`. Between initialization and the first sync,
the catalog therefore appears empty even though package IDs, metadata, and
telemetry remain intact. Sync marks current registry recipes as listed. Later
initialization calls preserve those flags and do not hide packages again.

For the search-snapshot upgrade, initialize the new derived table and publish its
first generation before routing traffic to the new reader. Stage the new code in
a separate Lambda version/function connected to the same database, invoke
`task_initdb_website`, then `task_sync_website` (or `task_publish_search` to retain
database-only metadata edits), and only then switch traffic. The old reader can
continue using the package tables during this preparation. If deploying in place,
search returns 503 until these tasks complete; package listings and overviews still
read the package tables. Repeated initialization preserves an existing snapshot.

Tasks run the code and content currently deployed in the website Lambda. Both LOCAL and PROD startup do no schema or
content synchronization; pages/posts query their rows on demand. Existing content
stays under `ttrek.sh/content`, and there is no separate patch Lambda project.
Local testing uses the existing `tdevops` website stack and the same invocation
payloads against its local Lambda endpoint. With `start-local` running, invoke
`ttrek run -script initdb-local` and `ttrek run -script sync-local` from another
terminal. The local stack is disposable, so repeat these after restarting it.

The pinned registry supplies `web-static-wiki` 0.1.4 and `web-static-blog` 0.1.3,
which provide the explicit initialization and synchronization procedures.
