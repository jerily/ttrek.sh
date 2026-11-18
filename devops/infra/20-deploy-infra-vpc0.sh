#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
RETAIN_ENDPOINTS=${TTREK_RETAIN_INTERFACE_ENDPOINTS:-false}
if [[ "$RETAIN_ENDPOINTS" != true && "$RETAIN_ENDPOINTS" != false ]]; then
  printf '%s\n' 'TTREK_RETAIN_INTERFACE_ENDPOINTS must be true or false.' >&2
  exit 2
fi

aws cloudformation deploy \
  --template-file "${SCRIPT_DIR}/20-infra-vpc0.yml" \
  --stack-name Infra-DevOps-TTREK-Base \
  --capabilities CAPABILITY_NAMED_IAM CAPABILITY_AUTO_EXPAND \
  --parameter-overrides "RetainInterfaceEndpoints=$RETAIN_ENDPOINTS" \
  --profile "${AWS_PROFILE:-ttrek-prod-neo}" \
  --region "${AWS_REGION:-${AWS_DEFAULT_REGION:-eu-central-1}}" \
  --no-fail-on-empty-changeset
