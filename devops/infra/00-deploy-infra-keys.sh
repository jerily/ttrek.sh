#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

aws cloudformation deploy \
  --template-file "${SCRIPT_DIR}/00-infra-keys.yml" \
  --stack-name Infra-DevOps-TTREK-Keys \
  --capabilities CAPABILITY_NAMED_IAM CAPABILITY_AUTO_EXPAND \
  --profile "${AWS_PROFILE:-ttrek-prod-neo}" \
  --region "${AWS_REGION:-${AWS_DEFAULT_REGION:-eu-central-1}}" \
  --no-fail-on-empty-changeset
