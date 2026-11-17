#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
API_FUNCTION=${LAMBDA_FUNCTION_NAME:-prod-Api-TtrekWebsite-Function}
# Examine the name portion so both bare names and full ARNs accept a qualifier.
if [[ ${API_FUNCTION##*:function:} != *:* ]]; then
  API_FUNCTION+=:DEFAULT
fi
HOSTED_ZONE_ID=$("${TCLSH:-tclsh}" "$SCRIPT_DIR/resolve-hosted-zone.tcl")
aws cloudformation deploy \
  --template-file "$SCRIPT_DIR/40-api-gateway.json" \
  --stack-name Infra-DevOps-TTREK-Api \
  --s3-bucket "${SAM_ARTIFACT_BUCKET:-jerily-ttrek-app}" \
  --parameter-overrides \
    "LambdaFunctionName=$API_FUNCTION" \
    "DomainName=${TTREK_DOMAIN_NAME:-ttrek.sh}" \
    "CertificateArn=${TTREK_CERTIFICATE_ARN:-}" \
    "HostedZoneId=$HOSTED_ZONE_ID" \
  --region "${AWS_REGION:-${AWS_DEFAULT_REGION:-eu-central-1}}" \
  --profile "${AWS_PROFILE:-ttrek-prod-neo}" \
  --no-fail-on-empty-changeset
aws cloudformation describe-stacks --stack-name Infra-DevOps-TTREK-Api \
  --query 'Stacks[0].Outputs' --output table \
  --region "${AWS_REGION:-${AWS_DEFAULT_REGION:-eu-central-1}}" \
  --profile "${AWS_PROFILE:-ttrek-prod-neo}"
