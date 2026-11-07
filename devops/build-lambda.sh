#!/usr/bin/env bash
set -euo pipefail

SITE_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
: "${CODEBUILD_SRC_DIR_Ttrek:?CodeBuild must check out the Ttrek secondary source}"
: "${CODEBUILD_SRC_DIR_PrivateRegistry:?CodeBuild must check out the PrivateRegistry secondary source}"
cd "$SITE_ROOT"

# The private registry supplies build tools; the pinned public registry supplies
# the site's runtime recipes. Keep both sources local during resolution.
git submodule update --init --recursive -- registry
export TTREK_BUILD_DIR="$SITE_ROOT/build/ttrek"
export TTREK_INSTALL_DIR="$SITE_ROOT/build/ttrek-prefix"
export JOBS=${TTREK_MAKE_THREADS:-4}
bash "$CODEBUILD_SRC_DIR_Ttrek/build-ttrek.sh"
export PATH="$TTREK_BUILD_DIR:$PATH"
ttrek install -y -registry "$CODEBUILD_SRC_DIR_PrivateRegistry" -registry "$SITE_ROOT/registry"

export TTREK_SITE_PREFIX="$SITE_ROOT/ttrek-venv/local"
export LD_LIBRARY_PATH="$TTREK_SITE_PREFIX/lib:$TTREK_SITE_PREFIX/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
TCLSH="$TTREK_SITE_PREFIX/bin/tclsh9.1"
ttrek run -script build-assets
ttrek run -script build-search
"$TCLSH" tests/all.tcl
"$TCLSH" tests/config.test
"$TCLSH" tests/lambda-config.test
"$TCLSH" tests/installer.tcl
# Keep the AL2023 ABI check enabled. A --local-only ZIP must never be deployed.
bash devops/generate-prod-config.sh
export TTREK_PRODUCTION_CONFIG="$SITE_ROOT/build/prod/config.ini"
ttrek run -script package-lambda
python3 devops/finalize-lambda.py dist/ttrek-sh.zip
sam validate --lint --template-file devops/sam-template.yaml
