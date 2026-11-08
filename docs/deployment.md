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

Production uses TLS Valkey for shared request-monitor history and global per-IP
rate limits (1000 requests per 10 seconds by default). The adapter uses API
Gateway's `requestContext.http.sourceIp`, not a caller-supplied forwarded header.
Download telemetry still uses SQLite in each execution environment, and production
release downloads remain disabled by the Lambda adapter.

Lambda and Valkey use one isolated subnet. There is no NAT gateway, internet gateway,
public subnet, load balancer or Fargate service. A private KMS interface endpoint
allows tconfig to decrypt the packaged configuration at startup. Lambda has no
runtime SSM access: SSM values are resolved by the build outside the VPC. The
security groups allow Lambda to reach only Valkey on 6379 and KMS on 443. Future
outbound AWS service calls need matching endpoints and policies; calls to public
third-party services would need internet egress. API Gateway invocation and
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
5. Run `15-deploy-infra-certificate.sh` and complete DNS validation.
6. Complete the GitHub connection setup below, run `30-deploy-codebuild.sh`, then
   run the build (or use the manual Lambda steps below).
7. Once Lambda exists and the certificate is issued, run `40-deploy-api-gateway.sh`.

If you deployed the previous two-zone network through step 2 but have not deployed
the cache or Lambda, rerun `devops/infra/20-deploy-infra-vpc0.sh`, then continue
with `25-deploy-infra-cache.sh`. Updating `Infra-DevOps-TTREK-Base` removes the
second endpoint interface, subnet, route-table association and subnet export.
The first subnet and its export remain. The keys and storage stacks need no
update for this change. New cache and Lambda deployments use only the first subnet.

If cache or Lambda stacks already import `Infra-DevOps-TTREK-Base-PrivateSubnet2Id`,
update those consumers to use the first subnet and wait for their resources to
release the second subnet before updating Base. A cache node using the second
subnet must be migrated before that subnet can be removed. CloudFormation
[blocks removal of an imported export](https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/using-cfn-stack-exports.html).

The keys template creates the customer-managed key used by tconfig and the SSM
password. Key rotation is enabled. `DeletionPolicy` and `UpdateReplacePolicy`
retain the key, since deleting it would make existing encrypted configuration
unreadable. The S3 bucket is also retained, blocks public access, and uses SSE-S3.
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

### Deployment IAM policy

The existing IAM group `ttrek_prod_admin_group` receives two customer managed
policies: `00-iam-policy-deploy.json` covers deployment commands, DNS and SSM;
`00-iam-policy-resources.json` covers CloudFormation resource operations.
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

The policies cover the application infrastructure scripts (Keys through Api): stack change
sets, KMS keys and aliases, the S3 bucket, isolated VPC, Valkey, ACM/DNS, CodeBuild
and its role, and the public API's Lambda invocation permission. Most resource
operations require CloudFormation's [forward access session](https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/fas-requests-and-permission-evaluation.html).
SSM reads and decryption through SSM are scoped to `/ttrek_sh/*`;
DNS changes are limited to A/CNAME records at `ttrek.sh` and `_*.ttrek.sh`.
Passing the build role is limited to CodeBuild. The first deployment can create
the ElastiCache and API Gateway service-linked roles.

These are infrastructure administrator policies: they use broader regional access
through CloudFormation for generated EC2, KMS, ACM and cache resource IDs, and
the deployer can edit the build role's inline permissions. These policies are not
permissions boundaries. Their fixed names match the templates' defaults; adjust them when changing
the application, bucket, domain or Lambda name. SSM writes, GitHub connection
setup, starting builds, and manual SAM deployments need separate permissions.
Stacks must use the caller's credentials, as the supplied scripts do; an existing
CloudFormation service role needs its own resource permissions.

IAM's [5,120-character inline group limit is cumulative](https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_iam-quotas.html),
so multiple inline policies would still hit it. Each managed policy has its own
6,144-character limit; the script checks both documents before deployment.
The two attachments use two of the group's ten managed-policy slots.

## Production and local configuration

You manage the SSM values; none of these scripts creates or updates them.
`devops/config.prod.ini` is a secret-free input template. tconfig resolves
`/ttrek_sh/prod/<section>/<key>` and encrypts SecureString values into the generated
`build/prod/config.ini`. That generated file is copied to `etc/config.ini` inside
the Lambda ZIP. The build fails if the password is missing, is not encrypted, or
the cache endpoint is missing. No plaintext secret is committed or printed.

| SSM parameter | Type | Value |
| --- | --- | --- |
| `/ttrek_sh/prod/redis/password` | SecureString | Required; 16–128 characters, encrypted with the Keys stack KMS key |
| `/ttrek_sh/prod/redis/host` | String | Required; cache primary endpoint from stack outputs |
| `/ttrek_sh/prod/redis/port` | String | Optional; default `6379` |
| `/ttrek_sh/prod/redis/username` | String | Optional; must match the cache user, currently `appuser` |
| `/ttrek_sh/prod/redis/ssl_ca_file` | String | Optional; AL2023 default `/etc/pki/tls/certs/ca-bundle.crt` |
| `/ttrek_sh/prod/ratelimit/window_millis` | String | Optional; default `10000` |
| `/ttrek_sh/prod/ratelimit/limit` | String | Optional; default `1000` |
| `/ttrek_sh/prod/request_monitor/history_max_events` | String | Optional; default `100000` |
| `/ttrek_sh/prod/request_monitor/master_template` | String | Optional; default `request-monitor-master.html.jinja` from `www/` |
| `/ttrek_sh/prod/request_monitor/store` | String | Optional; default `valkey`; `memory` keeps history within each process |

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
The mocks read it directly from the host; it is never packaged. Both local
request monitoring and rate limiting use memory, independent for each worker.
Local mode ignores any packaged production configuration and makes no SSM/KMS
calls. Direct server development still uses its existing Valkey configuration.

## CodeBuild

CodeBuild reads `devops/buildspec.yml`, selected by `Source.BuildSpec` in
`devops/infra/30-codebuild.yml`. The AL2023 x86_64 build image matches Lambda's
native-library ABI. Before running ttrek, the install phase installs GCC/G++,
Make, Bash, curl, Git, patch, pkg-config, Perl, tar, gzip and CA certificates,
plus ZIP and binary utilities for packaging. It installs CMake (`>=3.25,<5`)
and SAM with pip, then checks the CMake and compiler versions. These tools are
needed to build the site's dependencies even though ttrek itself is downloaded.
The build:

1. Downloads the rebuilt ttrek 1.0.0 Linux AMD64 glibc binary from
   `s3://jerily-ttrek-app/ttrek/1.0.0/linux-amd64-glibc/ttrek`, makes it executable,
   and checks that it starts with `ttrek self-update -version`.
2. Uses that binary to install from the private registry (build tools) and the
   pinned public `registry` submodule (runtime recipes).
3. Runs the project's asset and search builds, then the application checks.
4. Generates encrypted production config from SSM, packages with tdevops, and sets executable ZIP attributes. The AL2023 compatibility check remains enabled.
5. Validates and deploys `devops/sam-template.yaml` with SAM.

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
the `GitHubConnectionArn` template parameter. The template applies that
connection to both GitHub sources and grants the build role
`codeconnections:GetConnection` and `codeconnections:GetConnectionToken`
for that ARN. The build role also has `s3:GetObject` on
`arn:aws:s3:::jerily-ttrek-app/ttrek/*` to download published ttrek binaries.
The ttrek source checkout and `TtrekRef` parameter are no longer needed.
Source credentials apply to the listed repositories. For HTTPS Git
clones of other private repositories run by recipes, register the same connection
as CodeBuild's regional default GitHub credential:

```bash
aws codebuild import-source-credentials --server-type GITHUB \
  --auth-type CODECONNECTIONS \
  --token "$TTREK_GITHUB_CONNECTION_ARN" \
  --region eu-central-1 --profile admin
```

Replace `admin` with a profile allowed to call `codebuild:ImportSourceCredentials`;
the repository's deployment group policies do not include that setup permission.
This sets the account default for CodeBuild projects in that region. The enabled
`env.git-credential-helper: yes` supplies credentials to recipe Git clones; no
token belongs in `ttrek.json`, a clone URL, or the build log.
See [AWS's GitHub App connection instructions](https://docs.aws.amazon.com/codebuild/latest/userguide/connections-github-app.html)
and [source credential selection](https://docs.aws.amazon.com/codebuild/latest/userguide/multiple-access-tokens.html).

Run `devops/infra/30-deploy-codebuild.sh` again to apply the source, image,
permissions and environment changes. `LambdaStackName` and `LambdaFunctionName`
select deployment targets. The existing `${S3Prefix}-${AppName}` bucket stores
SAM artifacts. CodeBuild deploys only after all build commands succeed; it no
longer publishes ECR images or updates ECS.

For a manual deployment from an AL2023 build host with dependencies installed:

```bash
ttrek run -script build-assets
export AWS_PROFILE=ttrek-prod-neo AWS_REGION=eu-central-1
export TTREK_CONFIG_KMS_KEY=$(aws cloudformation describe-stacks \
  --stack-name Infra-DevOps-TTREK-Keys \
  --query 'Stacks[0].Outputs[?OutputKey==`TTrekKMSMasterKeyArn`].OutputValue | [0]' --output text)
bash devops/generate-prod-config.sh
TTREK_PRODUCTION_CONFIG="$PWD/build/prod/config.ini" ttrek run -script package-lambda
python3 devops/finalize-lambda.py dist/ttrek-sh.zip
sam validate --lint --template-file devops/sam-template.yaml
sam deploy --template-file devops/sam-template.yaml \
  --stack-name Infra-DevOps-TTREK-Lambda \
  --s3-bucket jerily-ttrek-app --s3-prefix lambda/ttrek-sh \
  --capabilities CAPABILITY_NAMED_IAM \
  --region eu-central-1 --profile ttrek-prod-neo
```

Use a normal AL2023 package for AWS; `--local-only` skips the ABI check and is
only for local tests. `finalize-lambda.py` sets the executable ZIP attributes for
`bootstrap` and `local/bin/tclsh`. CodeBuild performs this step automatically.

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
