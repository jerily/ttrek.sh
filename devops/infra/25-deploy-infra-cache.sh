#!/usr/bin/env bash
set -euo pipefail
# Never put the decrypted SSM value in arguments, environment variables or logs.
set +x
umask 077
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT
AWS_OPTIONS=(--region "${AWS_REGION:-${AWS_DEFAULT_REGION:-eu-central-1}}" --profile "${AWS_PROFILE:-ttrek-prod-neo}")
aws ssm get-parameter --name /ttrek_sh/prod/redis/password --with-decryption \
  --output json "${AWS_OPTIONS[@]}" > "$WORK/ssm.json"
python3 - "$WORK" <<'PY'
import json
import pathlib
import sys
work = pathlib.Path(sys.argv[1])
parameter = json.loads((work / 'ssm.json').read_text())['Parameter']
password = parameter['Value']
if parameter['Type'] != 'SecureString' or not 16 <= len(password) <= 128:
    sys.exit('SSM redis/password must be a SecureString containing 16-128 characters')
(work / 'parameters.json').write_text(json.dumps([{'ParameterKey': 'ValkeyPassword', 'ParameterValue': password}]))
(work / 'ssm.json').unlink()
PY
aws cloudformation deploy \
  --template-file "$SCRIPT_DIR/25-infra-cache.yml" \
  --stack-name Infra-DevOps-TTREK-Cache \
  --parameter-overrides "file://$WORK/parameters.json" \
  "${AWS_OPTIONS[@]}" --no-fail-on-empty-changeset
