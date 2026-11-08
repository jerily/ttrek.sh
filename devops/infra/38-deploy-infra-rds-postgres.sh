#!/usr/bin/env bash
set -euo pipefail
set +x
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
if [[ ${1:-} == --help ]]; then
  printf '%s\n' 'Deploy telemetry RDS, S3 backups and morning vacuum.' \
    'First deploy IAM policies and 20-infra-vpc0.yml; create the SSM SecureString:' \
    '  /ttrek_sh/prod/postgres/password' \
    'Requires Docker, Python 3 and AWS CLI. Optional environment overrides:' \
    '  TTREK_MAINTENANCE_ZIP (already built ZIP; skips Docker)' \
    '  TTREK_SCHEDULE_TIMEZONE (default America/New_York)' \
    '  TTREK_BACKUP_SCHEDULE (default cron(0 5 * * ? *))' \
    '  TTREK_VACUUM_SCHEDULE (default cron(0 6 * * ? *))'
  exit 0
fi
if [[ $# -ne 0 ]]; then printf '%s\n' 'Use --help for usage.' >&2; exit 2; fi
if [[ -z ${TTREK_MAINTENANCE_ZIP:-} ]]; then
  bash "$SCRIPT_DIR/../package-telemetry-maintenance.sh"
fi
MAINTENANCE_ZIP=${TTREK_MAINTENANCE_ZIP:-"$SCRIPT_DIR/../../build/telemetry/telemetry-maintenance.zip"}
AWS_OPTIONS=(--region "${AWS_REGION:-${AWS_DEFAULT_REGION:-eu-central-1}}" --profile "${AWS_PROFILE:-ttrek-prod-neo}" --no-cli-pager)
python3 "$SCRIPT_DIR/../telemetry/deploy.py" "$SCRIPT_DIR/38-infra-rds-postgres.yml" "$MAINTENANCE_ZIP" "${AWS_OPTIONS[@]}"
