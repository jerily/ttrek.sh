#!/usr/bin/env bash
set -euo pipefail
# Keep the decrypted SSM value in memory and pipes, never arguments, files or logs.
set +x
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
AWS_OPTIONS=(--region "${AWS_REGION:-${AWS_DEFAULT_REGION:-eu-central-1}}" --profile "${AWS_PROFILE:-ttrek-prod-neo}" --no-cli-pager)
python3 - "$SCRIPT_DIR/25-infra-cache.yml" "${AWS_OPTIONS[@]}" <<'PY'
import json
import subprocess
import sys

template, *aws_options = sys.argv[1:]
try:
    # A pipe avoids the installed AWS CLI's bad-fd failure on file-backed stdout.
    result = subprocess.run([
        'aws', 'ssm', 'get-parameter', '--name', '/ttrek_sh/prod/redis/password',
        '--with-decryption', '--output', 'json', *aws_options,
    ], stdout=subprocess.PIPE, text=True, check=True)
    try:
        parameter = json.loads(result.stdout)['Parameter']
        password = parameter['Value']
        valid = parameter['Type'] == 'SecureString' and isinstance(password, str) and 16 <= len(password) <= 128
    except (KeyError, TypeError, ValueError):
        valid = False
    if not valid:
        sys.exit('SSM redis/password must be a SecureString containing 16-128 characters')
    parameters = json.dumps([{'ParameterKey': 'ValkeyPassword', 'ParameterValue': password}])
    with subprocess.Popen([
        'aws', 'cloudformation', 'deploy', '--template-file', template,
        '--stack-name', 'Infra-DevOps-TTREK-Cache',
        '--parameter-overrides', 'file:///dev/stdin',
        *aws_options, '--no-fail-on-empty-changeset',
    ], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True) as deployment:
        deployment.stdin.write(parameters)
        deployment.stdin.close()
        for line in deployment.stdout:
            print(line, end='', flush=True)
        sys.exit(deployment.wait())
except subprocess.CalledProcessError as error:
    sys.exit(error.returncode)
PY
