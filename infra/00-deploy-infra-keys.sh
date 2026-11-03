#!/bin/bash

SCRIPT_DIR=$(dirname $(readlink -f $0))

aws cloudformation deploy \
  --template-file ${SCRIPT_DIR}/00-infra-keys.yml \
  --stack-name Infra-DevOps-TTREK-Keys \
  --capabilities CAPABILITY_NAMED_IAM CAPABILITY_AUTO_EXPAND \
  --profile ttrek-prod-neo
