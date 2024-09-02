#!/bin/bash

SCRIPT_DIR=$(dirname $(readlink -f $0))

aws cloudformation deploy \
  --template-file ${SCRIPT_DIR}/codebuild.yml \
  --stack-name Infra-DevOps-TTREK-Builds \
  --capabilities CAPABILITY_NAMED_IAM CAPABILITY_AUTO_EXPAND \
  --profile jrl-neo-dev
