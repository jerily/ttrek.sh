#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
aws cloudformation deploy \
  --template-file "$SCRIPT_DIR/16-infra-cloudfront-cdn.yml" \
  --stack-name Infra-DevOps-TTREK-CloudFrontCDN \
  --parameter-overrides \
    "ContentImagesBucket=${CONTENT_IMAGES_BUCKET:-jerily-ttrek-app}" \
    "ContentImagesPrefix=${CONTENT_IMAGES_PREFIX:-ttrek/content/images}" \
    "BrowserAssetsPrefix=${BROWSER_ASSETS_PREFIX:-cdn}" \
    "ImageCacheTTL=${CONTENT_IMAGES_CACHE_TTL:-300}" \
  --region "${AWS_REGION:-${AWS_DEFAULT_REGION:-eu-central-1}}" \
  --profile "${AWS_PROFILE:-ttrek-prod-neo}" \
  --no-fail-on-empty-changeset
