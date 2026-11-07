#!/usr/bin/env bash
set -euo pipefail
set +x
umask 077
SITE_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
. "$SITE_ROOT/bin/site-env.sh"
: "${TTREK_CONFIG_KMS_KEY:?Set TTREK_CONFIG_KMS_KEY to the Keys stack KMS ARN}"
mkdir -p "$SITE_ROOT/build/prod"
WORK=$(mktemp -d "$SITE_ROOT/build/prod/.config-XXXXXX")
trap 'rm -rf -- "$WORK"' EXIT
"$SITE_TCLSH" "$SITE_PREFIX/bin/tconfig-encrypt.tcl" \
  -application ttrek_sh -environment prod -aws_kms_key "$TTREK_CONFIG_KMS_KEY" \
  "$SITE_ROOT/devops/config.prod.ini" > "$WORK/config.ini"
"$SITE_TCLSH" "$SITE_ROOT/devops/validate-prod-config.tcl" "$WORK/config.ini"
mv -- "$WORK/config.ini" "$SITE_ROOT/build/prod/config.ini"
printf '%s\n' 'Generated encrypted build/prod/config.ini'
