#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

aws cloudformation deploy \
  --template-file "${SCRIPT_DIR}/31-codebuild-patch.yml" \
  --stack-name Infra-DevOps-TTREK-Patch \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
    "WebsiteFunctionName=${TTREK_WEBSITE_FUNCTION_NAME:-prod-Api-TtrekWebsite-Function}" \
    "TaskName=${TTREK_PATCH_TASK:-task_sync_website}" \
  --profile "${AWS_PROFILE:-ttrek-prod-neo}" \
  --region "${AWS_REGION:-${AWS_DEFAULT_REGION:-eu-central-1}}" \
  --no-fail-on-empty-changeset
