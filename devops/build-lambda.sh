#!/usr/bin/env bash
set -euo pipefail

SITE_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
: "${CODEBUILD_SRC_DIR_PrivateRegistry:?CodeBuild must check out the PrivateRegistry secondary source}"
cd "$SITE_ROOT"

# The rebuilt glibc release targets glibc 2.28, compatible with AL2023's 2.34.
TTREK_BIN_DIR="$SITE_ROOT/build/ttrek"
mkdir -p "$TTREK_BIN_DIR"
aws s3 cp s3://jerily-ttrek-app/ttrek/1.0.0/linux-amd64-glibc/ttrek \
  "$TTREK_BIN_DIR/ttrek" --only-show-errors
chmod 0755 "$TTREK_BIN_DIR/ttrek"
"$TTREK_BIN_DIR/ttrek" self-update -version
export PATH="$TTREK_BIN_DIR:$PATH"
export JOBS=${TTREK_MAKE_THREADS:-4}

# The private registry supplies build tools; the pinned public registry supplies
# the site's runtime recipes. Keep both sources local during resolution.
git submodule update --init --recursive -- registry
# Include the failing recipe's log in CodeBuild output for diagnosis.
ttrek install -y -fail-verbose -registry "$CODEBUILD_SRC_DIR_PrivateRegistry" -registry "$SITE_ROOT/registry"

export TTREK_SITE_PREFIX="$SITE_ROOT/ttrek-venv/local"
export LD_LIBRARY_PATH="$TTREK_SITE_PREFIX/lib:$TTREK_SITE_PREFIX/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
TCLSH="$TTREK_SITE_PREFIX/bin/tclsh9.1"
# Rehydrate previous fingerprints into every clean build, so older pages keep
# working after deployment. This prefix is covered by the existing lambda/* IAM
# permissions. Never use --delete on the append-only asset history.
: "${SAM_ARTIFACT_BUCKET:?CodeBuild must supply the SAM artifact bucket}"
ASSET_HISTORY="s3://$SAM_ARTIFACT_BUCKET/lambda/ttrek-sh-assets/"
mkdir -p public/assets/versioned
aws s3 sync "$ASSET_HISTORY" public/assets/versioned/ --only-show-errors
ttrek run -script build-assets
npm test
ttrek run -script build-search
"$TCLSH" tests/all.tcl
"$TCLSH" tests/static-content.test
"$TCLSH" tests/content-images.test
"$TCLSH" tests/content-images-build.test
"$TCLSH" tests/config.test
"$TCLSH" tests/lambda-config.test
"$TCLSH" tests/telemetry-config.test
"$TCLSH" tests/telemetry.test
"$TCLSH" tests/registry-metadata.test
"$TCLSH" tests/telemetry-maintenance.test
"$TCLSH" tests/installer.tcl
bash devops/generate-prod-config.sh
export TTREK_PRODUCTION_CONFIG="$SITE_ROOT/build/prod/config.ini"
# Build on AL2023 and skip tdevops' numeric glibc cutoff, which rejects backports.
ttrek run -script package-lambda -- --local-only
python3 devops/finalize-lambda.py dist/ttrek-sh.zip
"$TCLSH" tests/lambda-package.tcl dist/ttrek-sh.zip
sam validate --lint --template-file devops/sam-template.yaml
"$TCLSH" devops/upload-content-images.tcl "$TTREK_PRODUCTION_CONFIG"
aws s3 sync public/assets/versioned/ "$ASSET_HISTORY" --only-show-errors
