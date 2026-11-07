#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
aws cloudformation deploy \
  --template-file "$SCRIPT_DIR/api-gateway.json" \
  --stack-name Infra-DevOps-TTREK-Api \
  --parameter-overrides \
    "LambdaFunctionName=${LAMBDA_FUNCTION_NAME:-prod-Api-TtrekWebsite-Function}" \
    "DomainName=${TTREK_DOMAIN_NAME:-ttrek.sh}" \
    "CertificateArn=${TTREK_CERTIFICATE_ARN:-}" \
    "HostedZoneId=${TTREK_HOSTED_ZONE_ID:-}" \
  --region "${AWS_REGION:-${AWS_DEFAULT_REGION:-eu-central-1}}" \
  --profile "${AWS_PROFILE:-ttrek-prod-neo}" \
  --no-fail-on-empty-changeset
aws cloudformation describe-stacks --stack-name Infra-DevOps-TTREK-Api \
  --query 'Stacks[0].Outputs' --output table \
  --region "${AWS_REGION:-${AWS_DEFAULT_REGION:-eu-central-1}}" \
  --profile "${AWS_PROFILE:-ttrek-prod-neo}"
