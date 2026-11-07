#!/usr/bin/env bash
set -euo pipefail
umask 077

DRY_RUN=false
case "${1:-}" in
  --dry-run) DRY_RUN=true; shift ;;
  -h|--help)
    printf '%s\n' 'Usage: 00-deploy-iam-policy.sh [--dry-run]' \
      'Deploys two managed policies for ttrek_prod_admin_group through CloudFormation.' \
      'Use an administrator AWS_PROFILE in the deployment account.' \
      '--dry-run prints the rendered CloudFormation template without changing AWS.'
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

# Keep permissions in the two 00-iam-policy-*.json files.
python3 - "$SCRIPT_DIR" "$WORK/template.json" "$ACCOUNT_ID" "$REGION" <<'PY'
import json
import pathlib
import re
import sys

source, destination, account, region = sys.argv[1:]
if not re.fullmatch(r'[0-9]{12}', account):
    sys.exit('STS did not return a 12-digit AWS account ID')
if not re.fullmatch(r'[a-z]{2}(?:-[a-z]+)+-[0-9]+', region):
    sys.exit('Invalid AWS region')
resources = {}
for suffix, name in [('deploy', 'TTrekInfrastructureDeploy'), ('resources', 'TTrekInfrastructureResources')]:
    path = pathlib.Path(source) / f'00-iam-policy-{suffix}.json'
    text = path.read_text().replace('__ACCOUNT_ID__', account).replace('__REGION__', region)
    policy = json.loads(text)
    size = len(json.dumps(policy, separators=(',', ':')))
    if size > 6144:
        sys.exit(f'{path.name} exceeds the 6,144-character managed policy limit ({size} characters)')
    resources[name] = {
        'Type': 'AWS::IAM::ManagedPolicy',
        'Properties': {
            'ManagedPolicyName': name,
            'Groups': ['ttrek_prod_admin_group'],
            'PolicyDocument': policy,
        },
    }
template = {
    'AWSTemplateFormatVersion': '2010-09-09',
    'Description': 'Deployment permissions for ttrek_prod_admin_group.',
    'Resources': resources,
}
pathlib.Path(destination).write_text(json.dumps(template, indent=2) + '\n')
PY

if $DRY_RUN; then
  cat "$WORK/template.json"
  exit 0
fi

aws cloudformation deploy \
  --template-file "$WORK/template.json" \
  --stack-name Infra-DevOps-TTREK-Permissions \
  --capabilities CAPABILITY_NAMED_IAM \
  --no-fail-on-empty-changeset \
  "${AWS_OPTIONS[@]}"

aws iam list-attached-group-policies --group-name ttrek_prod_admin_group \
  --query 'AttachedPolicies[].PolicyArn' --output json \
  "${AWS_OPTIONS[@]}" > "$WORK/attached.json"
python3 - "$WORK/attached.json" "$ACCOUNT_ID" <<'PY'
import json
import pathlib
import sys

attached = set(json.loads(pathlib.Path(sys.argv[1]).read_text()))
for name in ['TTrekInfrastructureDeploy', 'TTrekInfrastructureResources']:
    arn = f'arn:aws:iam::{sys.argv[2]}:policy/{name}'
    if arn not in attached:
        sys.exit(f'Missing group attachment: {arn}; retaining the inline policy')
PY

# Migrate only our old inline policy, after CloudFormation attaches both replacements.
HAS_INLINE_POLICY=$(aws iam list-group-policies \
  --group-name ttrek_prod_admin_group \
  --query "contains(PolicyNames, 'TTrekInfrastructureDeploy')" --output text \
  "${AWS_OPTIONS[@]}")
if [[ $HAS_INLINE_POLICY == True ]]; then
  aws iam delete-group-policy \
    --group-name ttrek_prod_admin_group \
    --policy-name TTrekInfrastructureDeploy \
    "${AWS_OPTIONS[@]}"
fi
printf '%s\n' 'Updated deployment managed policies on ttrek_prod_admin_group.'
