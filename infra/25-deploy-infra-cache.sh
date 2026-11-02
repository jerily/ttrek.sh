#!/bin/bash

SCRIPT_DIR=$(dirname $(readlink -f $0))

aws cloudformation deploy \
  --template-file ${SCRIPT_DIR}/25-infra-cache.yml \
  --stack-name Infra-DevOps-TTREK-Cache \
  --parameter-overrides "ValkeyPassword=${TTREK_VALKEY_PASSWORD:?Set TTREK_VALKEY_PASSWORD to the Valkey password}" \
  --capabilities CAPABILITY_NAMED_IAM CAPABILITY_AUTO_EXPAND \
  --profile jrl-neo-dev
