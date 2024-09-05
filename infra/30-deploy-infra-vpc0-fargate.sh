#!/bin/bash

SCRIPT_DIR=$(dirname $(readlink -f $0))

aws cloudformation deploy \
  --template-file ${SCRIPT_DIR}/infra-vpc0-fargate.yml \
  --stack-name Infra-DevOps-TTREK-App \
  --capabilities CAPABILITY_NAMED_IAM CAPABILITY_AUTO_EXPAND \
  --profile jrl-neo-dev