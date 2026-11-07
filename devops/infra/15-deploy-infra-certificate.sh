#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
if [[ -z ${TTREK_HOSTED_ZONE_ID:-} ]]; then
  printf '%s\n' 'Add the DNS validation CNAME shown in ACM; this deployment waits for validation.'
fi
aws cloudformation deploy \
  --template-file "$SCRIPT_DIR/15-infra-certificate.yml" \
  --stack-name Infra-DevOps-TTREK-Certificate \
  --parameter-overrides "DomainName=${TTREK_DOMAIN_NAME:-ttrek.sh}" "HostedZoneId=${TTREK_HOSTED_ZONE_ID:-}" \
  --region "${AWS_REGION:-${AWS_DEFAULT_REGION:-eu-central-1}}" \
  --profile "${AWS_PROFILE:-ttrek-prod-neo}" \
  --no-fail-on-empty-changeset
