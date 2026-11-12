#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${TTREK_GITHUB_CONNECTION_ARN:-}" ]]; then
  cat >&2 <<'EOF'
Error: TTREK_GITHUB_CONNECTION_ARN must be set to a non-empty AWS CodeConnections connection ARN.

Install and connect AWS Connector for GitHub:
  1. Open https://github.com/marketplace/aws-connector-for-github
  2. Click Add, then Install it for free if prompted.
  3. Select the personal GitHub account jerily.
  4. Choose Only select repositories and include:
     ttrek.sh, private-ttrek-registry, tdevops,
     mock-lambda-app, mock-proxy-app, mock-s3-app.
  5. Click Install. The app will appear under Installed GitHub Apps,
     where you can manage repository access.
  6. Return to the AWS connection wizard in your deployment region
     (eu-central-1 by default), select that installation, and complete
     the connection. Its status must be Available.

Export the resulting connection ARN, then rerun this script:
  export TTREK_GITHUB_CONNECTION_ARN='arn:aws:codeconnections:eu-central-1:ACCOUNT_ID:connection/CONNECTION_ID'

See docs/deployment.md for CodeBuild's default GitHub credential setup.
EOF
  exit 1
fi

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

aws cloudformation deploy \
  --template-file "${SCRIPT_DIR}/30-codebuild.yml" \
  --stack-name Infra-DevOps-TTREK-Builds \
  --capabilities CAPABILITY_NAMED_IAM CAPABILITY_AUTO_EXPAND \
  --parameter-overrides "GitHubConnectionArn=${TTREK_GITHUB_CONNECTION_ARN}" \
    "ContentImagesBucket=${CONTENT_IMAGES_BUCKET:-jerily-ttrek-app}" \
    "ContentImagesPrefix=${CONTENT_IMAGES_PREFIX:-ttrek/content/images}" \
    "BrowserAssetsPrefix=${BROWSER_ASSETS_PREFIX:-cdn}" \
  --profile "${AWS_PROFILE:-ttrek-prod-neo}" \
  --region "${AWS_REGION:-${AWS_DEFAULT_REGION:-eu-central-1}}" \
  --no-fail-on-empty-changeset
