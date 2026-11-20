#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
if (( $# > 1 )); then
  echo 'Usage: upload-content.sh [AWS_PROFILE]' >&2
  exit 2
fi
profile=()
if [[ -n ${1:-} ]]; then
  profile=(--profile "$1")
elif [[ -z ${CODEBUILD_BUILD_ID:-} ]]; then
  profile=(--profile "${AWS_PROFILE:-ttrek-prod-neo}")
fi
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
if [[ ! -d content/docs || ! -d content/blog ]]; then
  echo 'The content archive requires content/docs and content/blog.' >&2
  exit 1
fi
if [[ -n $(find content -type l -print -quit) ]]; then
  echo 'The content archive cannot include symbolic links.' >&2
  exit 1
fi
zip -q -r -MM "$work/content.zip" content
aws s3 cp "$work/content.zip" "s3://${CONTENT_IMAGES_BUCKET:-jerily-ttrek-app}/ttrek/content/latest.zip" \
  "${profile[@]}" --region "${AWS_REGION:-${AWS_DEFAULT_REGION:-eu-central-1}}" --only-show-errors
