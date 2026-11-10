#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
HOSTED_ZONE_ID=$("${TCLSH:-tclsh}" "$SCRIPT_DIR/resolve-hosted-zone.tcl")
if [[ -z $HOSTED_ZONE_ID ]]; then
  printf '%s\n' 'Publish the SES stack DNS outputs at your DNS provider before sending email.'
fi
aws cloudformation deploy \
  --template-file "$SCRIPT_DIR/45-infra-ses.yml" \
  --stack-name Infra-DevOps-TTREK-SES \
  --parameter-overrides \
    "DomainName=${TTREK_DOMAIN_NAME:-ttrek.sh}" \
    "HostedZoneId=$HOSTED_ZONE_ID" \
    "MailFromSubdomain=${TTREK_SES_MAIL_FROM_SUBDOMAIN:-bounce}" \
    "ConfigurationSetName=${TTREK_SES_CONFIGURATION_SET:-ttrek-transactional}" \
    "ManageDmarcRecord=${TTREK_SES_MANAGE_DMARC:-false}" \
    "DmarcPolicy=${TTREK_SES_DMARC_POLICY:-none}" \
  --region "${AWS_REGION:-${AWS_DEFAULT_REGION:-eu-central-1}}" \
  --profile "${AWS_PROFILE:-ttrek-prod-neo}" \
  --no-cli-pager \
  --no-fail-on-empty-changeset
