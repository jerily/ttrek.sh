#!/usr/bin/env bash
set -euo pipefail
umask 077

DRY_RUN=false
case "${1:-}" in
  --dry-run) DRY_RUN=true; shift ;;
  -h|--help)
    printf '%s\n' 'Usage: 00-deploy-iam-policy.sh [--dry-run]' \
      'Sets the TTrekInfrastructureDeploy inline policy on ttrek_prod_admin_group.' \
      'Use an administrator AWS_PROFILE in the deployment account.' \
      '--dry-run prints the rendered policy without changing IAM.'
    exit 0
    ;;
esac
if [[ $# -ne 0 ]]; then
  printf '%s\n' 'Usage: 00-deploy-iam-policy.sh [--dry-run]' >&2
  exit 2
fi

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REGION=${AWS_REGION:-${AWS_DEFAULT_REGION:-eu-central-1}}
AWS_OPTIONS=(--profile "${AWS_PROFILE:-ttrek-prod-neo}" --region "$REGION" --no-cli-pager)
WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text "${AWS_OPTIONS[@]}")

# Keep the policy document in 00-iam-policy.json; substitute only deployment identifiers.
python3 - "$SCRIPT_DIR/00-iam-policy.json" "$WORK/policy.json" "$ACCOUNT_ID" "$REGION" <<'PY'
import json
import pathlib
import re
import sys

source, destination, account, region = sys.argv[1:]
if not re.fullmatch(r'[0-9]{12}', account):
    sys.exit('STS did not return a 12-digit AWS account ID')
if not re.fullmatch(r'[a-z]{2}(?:-[a-z]+)+-[0-9]+', region):
    sys.exit('Invalid AWS region')
text = pathlib.Path(source).read_text().replace('__ACCOUNT_ID__', account).replace('__REGION__', region)
policy = json.dumps(json.loads(text), separators=(',', ':'))
if len(policy) > 5120:
    sys.exit(f'Policy exceeds the 5,120-character inline group limit ({len(policy)} characters)')
pathlib.Path(destination).write_text(policy + '\n')
PY

if $DRY_RUN; then
  python3 -m json.tool "$WORK/policy.json"
  exit 0
fi

aws iam put-group-policy \
  --group-name ttrek_prod_admin_group \
  --policy-name TTrekInfrastructureDeploy \
  --policy-document "file://$WORK/policy.json" \
  "${AWS_OPTIONS[@]}"
printf '%s\n' 'Updated TTrekInfrastructureDeploy on ttrek_prod_admin_group.'
