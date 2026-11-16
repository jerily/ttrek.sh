#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
aws cloudformation deploy \
  --template-file "$SCRIPT_DIR/46-infra-sqs.yml" \
  --stack-name Infra-DevOps-TTREK-SQS \
  --parameter-overrides "QueueName=${TTREK_EMAIL_QUEUE_NAME:-sqs_user_emails_queue}" \
  --region "${AWS_REGION:-${AWS_DEFAULT_REGION:-eu-central-1}}" \
  --profile "${AWS_PROFILE:-ttrek-prod-neo}" \
  --no-cli-pager \
  --no-fail-on-empty-changeset
