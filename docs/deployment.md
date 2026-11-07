# Deployment

[Documentation](readme.md) · [Project overview](../README.md)

Run these commands from the website checkout. See [setup](install.md) for
dependencies, [local development](local-development.md) for previewing changes,
and [binary distributions](releases.md) for release download configuration.

## Lambda and CodeBuild

`devops/sam-template.yaml` deploys the packaged Tcl Lambda on `provided.al2023`,
with an HTTP API for `/` and `/{proxy+}`, a scoped logging role, and 14-day log
retention. `Architecture` must match the native libraries in the ZIP (x86_64 by
default). Public assets, content, and the built search indexes are included in
the archive. The existing Lambda adapter keeps telemetry and request-monitor
state local to each execution environment; it does not use the direct server's
Valkey configuration or enable production release downloads.

CodeBuild reads `devops/buildspec.yml`, selected by `Source.BuildSpec` in
`devops/infra/30-codebuild.yml`. The AL2023 x86_64 build image matches Lambda's
native-library ABI. The build:

1. Compiles the `Ttrek` secondary source with its `build-ttrek.sh`.
2. Uses that binary to install from the private registry (build tools) and the
   pinned public `registry` submodule (runtime recipes).
3. Runs the project's asset and search builds, then the application checks.
4. Packages with tdevops, leaving its AL2023 compatibility check enabled.
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
ttrek run -script package-lambda
sam validate --lint --template-file devops/sam-template.yaml
sam deploy --template-file devops/sam-template.yaml \
  --stack-name Infra-DevOps-TTREK-Lambda \
  --s3-bucket jerily-ttrek-app --s3-prefix lambda/ttrek-sh \
  --capabilities CAPABILITY_NAMED_IAM \
  --region eu-central-1 --profile ttrek-prod-neo
```

Use a normal AL2023 package for AWS; `--local-only` skips the ABI check and is
only for local tests. This workflow does not rewrite archive execution bits.
The ZIP produced by the current packager needs executable permissions on
`bootstrap` and `local/bin/tclsh` before AWS can invoke it; that permission step
remains caller-managed.

The existing EC2/CodeDeploy and Fargate templates remain under `devops/` for
those deployments. They are not used by the Lambda build. The source AppSpec
is `devops/appspec.yml`; a CodeDeploy revision must stage it at the archive root
alongside `codedeploy-scripts/` and `ttrek-app/`. Existing deployment scripts use
the `ttrek-prod-neo` profile and `eu-central-1`.

The cache follows the Valkey 8.2 setup with one `cache.t4g.micro` node, TLS
required, an `appuser` account, and a disabled default user. Set
`TTREK_VALKEY_PASSWORD` (16-128 characters) before running the cache deployment
script; it supplies the `NoEcho` CloudFormation password parameter. User and
user-group IDs include `AppName` to avoid collisions with other deployments.
The cache stack exports `Infra-DevOps-TTREK-Cache-ValkeyClusterId` and
`Infra-DevOps-TTREK-Cache-ValkeyClusterEndpointAddress`.

`valkey-tcl` 1.0.3, `tratelimit` 1.0.1, and `treqmon` 2.0.0 are direct application
dependencies. The registry and build use libvalkey 0.5.0 with TLS enabled.
Production rate-limit counters and request-monitor history both use Valkey over
verified TLS with `appuser`. Configure `[redis]` keys `host`, `port`, `username`,
`password` and `ssl_ca_file`. Production's CA file defaults to `/etc/ssl/certs/ca-certificates.crt`;
set `/ttrek_sh/prod/redis/password` as an SSM SecureString before building the
encrypted config. The password must match the cache deployment password.

Previously `valkey-tcl` was installed transitively through `tratelimit` and
`treqmon`. Rate limits used sorted sets under `__RL__/...`; request history used
the `history_events` list, not the optional memory store. Download telemetry
uses SQLite. The registered `tsession-valkey` package was not a site dependency.

The VPC uses one availability zone. The load balancer and a single NAT gateway
have public IPs in the public subnet; Fargate and Valkey use the private subnet.
Outbound traffic uses NAT instead of VPC endpoints. Egress therefore depends
on that one availability zone.

The VPC deployment retains the `Infra-DevOps-TTREK-Base` stack name and its
remaining exports. For an existing deployment, migrate the ECR repository and
S3 bucket into `Infra-DevOps-TTREK-Storage` using CloudFormation resource
refactoring or retain/import before applying the split templates; a normal
deployment cannot move existing resources between stacks. The cache stack
creates a new Valkey replication group, so migrate any required Redis data
before retiring the old cache.

## API Gateway template

```sh
ttrek install -force -registry ../private-ttrek-registry -add-pubreg tdevops mock-proxy-app
ttrek run -package tdevops -script generate-api-gateway
```

This writes `dist/api-gateway.json` from `etc/routes.json`, selected by
`routes` in `etc/tdevops.tcl`. Deployment defaults live
under `apiGateway`; the CLI only selects input/output files. The template exposes
API name, stage, timeout, backend function and `AuthorizerFunction` parameters.
Authorization starts disabled because `authorizer.function` is empty. Supply an
existing Lambda name or ARN there, or through the CloudFormation parameter, to
enable it. `authorizer.excludePaths` lists exact configured paths that stay public
for every method. Add explicit routes for public pages beneath a protected catch-all.
The local mock ignores these deployment settings. Template generation does not deploy AWS resources.
