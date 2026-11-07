# Deployment

[Documentation](readme.md) · [Project overview](../README.md)

Run these commands from the website checkout. See [setup](install.md) for
dependencies, [local development](local-development.md) for previewing changes,
and [binary distributions](releases.md) for release download configuration.

## Lambda and CodeBuild

`devops/sam-template.yaml` deploys `prod-Api-TtrekWebsite-Function` on
`provided.al2023`, with private VPC access, a scoped execution role, and 14-day
log retention. `devops/infra/api-gateway.json` owns the HTTP API for `/` and
`/{proxy+}` and its `https://ttrek.sh/` custom domain. SAM does not create a second
API. `Architecture` must match the native libraries in the ZIP (x86_64 by default).

Production uses TLS Valkey for shared request-monitor history and global per-IP
rate limits (1000 requests per 10 seconds by default). The adapter uses API
Gateway's `requestContext.http.sourceIp`, not a caller-supplied forwarded header.
Download telemetry still uses SQLite in each execution environment, and production
release downloads remain disabled by the Lambda adapter.

Lambda and Valkey use isolated subnets. There is no NAT gateway, internet gateway,
public subnet, load balancer or Fargate service. A private KMS interface endpoint
allows tconfig to decrypt the packaged configuration at startup. Lambda has no
runtime SSM access: SSM values are resolved by the build outside the VPC. The
security groups allow Lambda to reach only Valkey on 6379 and KMS on 443. Future
outbound AWS service calls need matching endpoints and policies; calls to public
third-party services would need internet egress. API Gateway invocation and
Lambda's normal stdout/stderr logging do not need a NAT gateway.

The subnets and KMS endpoint span two availability zones. Valkey remains one
`cache.t4g.micro` node, without a replica or automatic failover; the cache is a
single point of failure. Shared history is bounded and is not a durable audit log.

## Infrastructure and DNS

Use the same AWS account and region for all stacks. Scripts default to
`AWS_PROFILE=ttrek-prod-neo` and `AWS_REGION=eu-central-1`; both are overridable.
For a new deployment:

1. Run `devops/infra/00-deploy-infra-keys.sh` and `10-deploy-infra-storage.sh`.
2. Run `devops/infra/20-deploy-infra-vpc0.sh`.
3. Create the SSM password described below, then run `25-deploy-infra-cache.sh`.
4. Set the SSM cache host to the cache stack's `TTrekValkeyClusterEndpointAddress` output.
5. Run `15-deploy-infra-certificate.sh` and complete DNS validation.
6. Deploy `30-codebuild.yml`, then run the build (or use the manual Lambda steps below).
7. Once Lambda exists and the certificate is issued, run `40-deploy-api-gateway.sh`.

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

The cache deployment script reads that same password with decryption and supplies
the `NoEcho` CloudFormation parameter through a mode-restricted temporary JSON
file, removed on exit. It does not put the password in command arguments or an
environment variable. Do not run secret-handling commands with AWS CLI debug
logging. Updating SSM alone does not update a running deployment: password
rotation requires a coordinated cache update and Lambda rebuild/deployment.

For local Lambda mocks, copy `etc/config.local.ini.example` to the ignored
`etc/config.local.ini`. `TTREK_LOCAL_CONFIG` can select another local file.
The mocks read it directly from the host; it is never packaged. Both local
request monitoring and rate limiting use memory, independent for each worker.
Local mode ignores any packaged production configuration and makes no SSM/KMS
calls. Direct server development still uses its existing Valkey configuration.

## CodeBuild

CodeBuild reads `devops/buildspec.yml`, selected by `Source.BuildSpec` in
`devops/infra/30-codebuild.yml`. The AL2023 x86_64 build image matches Lambda's
native-library ABI. The build:

1. Compiles the `Ttrek` secondary source with its `build-ttrek.sh`.
2. Uses that binary to install from the private registry (build tools) and the
   pinned public `registry` submodule (runtime recipes).
3. Runs the project's asset and search builds, then the application checks.
4. Generates encrypted production config from SSM, packages with tdevops, and sets executable ZIP attributes. The AL2023 compatibility check remains enabled.
5. Validates and deploys `devops/sam-template.yaml` with SAM.

CodeBuild checks out `PrivateRegistry` as a secondary source. Its GitHub
credentials must permit access to `private-ttrek-registry`, `tdevops` and the
mock-tool source repositories. The build enables CodeBuild's Git credential
helper for private recipe downloads. `PrivateRegistryRef` selects the registry
branch/tag/commit. Node/npm are supplied by the build image, and SAM is installed
as a build tool. Neither is a ttrek dependency.

To authenticate the private registry, create an AWS CodeConnections connection
to GitHub in the build's region and complete the GitHub App installation for the
`jerily` organization. Grant it access to `ttrek.sh`, `ttrek`,
`private-ttrek-registry`, `tdevops`, and any private source repositories referenced
by those recipes, including the mock apps. Finish the connection handshake so
its status is `AVAILABLE`, then pass its ARN when updating the build stack:

```bash
aws cloudformation deploy --template-file devops/infra/30-codebuild.yml \
  --stack-name Infra-DevOps-TTREK-Builds --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides GitHubConnectionArn=arn:aws:codeconnections:eu-central-1:ACCOUNT:connection/ID \
  --region eu-central-1 --profile ttrek-prod-neo
```

The template applies that connection to all three GitHub sources and grants the
build role `codeconnections:GetConnection` and `codeconnections:GetConnectionToken`
for that ARN. Source credentials apply to the listed repositories. For HTTPS Git
clones of other private repositories run by recipes, register the same connection
as CodeBuild's regional default GitHub credential:

```bash
aws codebuild import-source-credentials --server-type GITHUB \
  --auth-type CODECONNECTIONS \
  --token arn:aws:codeconnections:eu-central-1:ACCOUNT:connection/ID \
  --region eu-central-1 --profile ttrek-prod-neo
```

This sets the account default for CodeBuild projects in that region. The enabled
`env.git-credential-helper: yes` supplies credentials to recipe Git clones; no
token belongs in `ttrek.json`, a clone URL, or the build log.
If `GitHubConnectionArn` is empty, CodeBuild uses the account's configured default
GitHub source credentials instead. A private repository requires either setup.
See [AWS's GitHub App connection instructions](https://docs.aws.amazon.com/codebuild/latest/userguide/connections-github-app.html)
and [source credential selection](https://docs.aws.amazon.com/codebuild/latest/userguide/multiple-access-tokens.html).

Redeploy `devops/infra/30-codebuild.yml` to apply the source, image, permissions
and environment changes. `TtrekRef` selects the CLI branch/tag/commit;
`LambdaStackName` and `LambdaFunctionName` select deployment targets. The existing
`${S3Prefix}-${AppName}` bucket stores SAM artifacts. CodeBuild deploys only after
all build commands succeed; it no longer publishes ECR images or updates ECS.

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
ttrek run -package tdevops -script generate-api-gateway
```

This writes a generic `dist/api-gateway.json` from `etc/routes.json`, selected by
`routes` in `etc/tdevops.tcl`. Deployment defaults live
under `apiGateway`; the CLI only selects input/output files. The template exposes
API name, stage, timeout, backend function and `AuthorizerFunction` parameters.
Authorization starts disabled because `authorizer.function` is empty. Supply an
existing Lambda name or ARN there, or through the CloudFormation parameter, to
enable it. `authorizer.excludePaths` lists exact configured paths that stay public
for every method. Add explicit routes for public pages beneath a protected catch-all.
The local mock ignores these deployment settings. Template generation does not deploy AWS resources.

Deploy the maintained copy at `devops/infra/api-gateway.json`. It adds the domain,
certificate selection, root API mapping and optional Route 53 alias to the generated
base. When routes change, compare the generated template and carry the route and
integration changes into the maintained copy; do not overwrite its domain resources.
