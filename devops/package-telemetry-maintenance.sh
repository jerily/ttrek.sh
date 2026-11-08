#!/usr/bin/env bash
set -euo pipefail
SITE_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
mkdir -p "$SITE_ROOT/build/telemetry"
# Build against the same OS/architecture as the Python 3.13 Lambda runtime.
# Package installation occurs here, never inside the isolated production VPC.
docker run --rm --platform linux/amd64 \
  --mount "type=bind,src=$SITE_ROOT,dst=/source,readonly" \
  --mount "type=bind,src=$SITE_ROOT/build/telemetry,dst=/output" \
  public.ecr.aws/amazonlinux/amazonlinux:2023 \
  bash -ceu 'dnf install -y postgresql17 python3 && python3 /source/devops/telemetry/package.py'
