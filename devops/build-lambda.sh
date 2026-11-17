#!/usr/bin/env bash
set -euo pipefail

SITE_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
: "${CODEBUILD_SRC_DIR_PrivateRegistry:?CodeBuild must check out the PrivateRegistry secondary source}"
cd "$SITE_ROOT"

# The rebuilt glibc release targets glibc 2.28, compatible with AL2023's 2.34.
TTREK_BIN_DIR="$SITE_ROOT/build/ttrek"
mkdir -p "$TTREK_BIN_DIR"
# Override with an artifact built from ttrek's installation USE-flag changes.
TTREK_BINARY_S3_URI=${TTREK_BINARY_S3_URI:-s3://jerily-ttrek-app/ttrek/1.6.0/linux-amd64-glibc/ttrek}
aws s3 cp "$TTREK_BINARY_S3_URI" \
  "$TTREK_BIN_DIR/ttrek" --only-show-errors
chmod 0755 "$TTREK_BIN_DIR/ttrek"
"$TTREK_BIN_DIR/ttrek" self-update -version
export PATH="$TTREK_BIN_DIR:$PATH"
export JOBS=${TTREK_MAKE_THREADS:-4}

# Resolve dependencies and publish the catalog from one public checkout.
export TTREK_PUBLIC_REGISTRY="$SITE_ROOT/build/public-registry"
ttrek sync "$TTREK_PUBLIC_REGISTRY"

# The private registry supplies build tools; public packages come from the
# synced checkout that packaging will reuse for the website's later sync.
# Include the failing recipe's log in CodeBuild output for diagnosis.
# Reusing a local prefix can retain excluded files. CodeBuild must package a
# fresh production installation, with the SQLite-backed tests isolated below.
if [[ -e "$SITE_ROOT/ttrek-venv/ttrek-manifest.json" ]]; then
  echo "Production packaging requires a fresh ttrek-venv; use a clean checkout." >&2
  exit 1
fi
ttrek use-flags add -local
ttrek install -y -fail-verbose -registry "$CODEBUILD_SRC_DIR_PrivateRegistry" \
  -registry "$TTREK_PUBLIC_REGISTRY"

# Tests use SQLite and local mocks without adding either to the deployment.
TEST_PROJECT="$SITE_ROOT/build/test-deps"
mkdir -p "$TEST_PROJECT"
cp ttrek.json ttrek-lock.json "$TEST_PROJECT/"
(
  cd "$TEST_PROJECT"
  ttrek use-flags add +local
  ttrek install -y -fail-verbose -registry "$CODEBUILD_SRC_DIR_PrivateRegistry" \
    -registry "$TTREK_PUBLIC_REGISTRY"
)
TEST_PREFIX="$TEST_PROJECT/ttrek-venv/local"
export TTREK_PREPARE_TEST_PREFIX="$TEST_PREFIX"

export TTREK_SITE_PREFIX="$SITE_ROOT/ttrek-venv/local"
export LD_LIBRARY_PATH="$TTREK_SITE_PREFIX/lib:$TTREK_SITE_PREFIX/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
TCLSH="$TTREK_SITE_PREFIX/bin/tclsh9.1"
"$TCLSH" tests/runtime-packages.tcl --production
# Rehydrate previous fingerprints into every clean build, so older pages keep
# working after deployment. This prefix is covered by the existing lambda/* IAM
# permissions. Never use --delete on the append-only asset history.
: "${SAM_ARTIFACT_BUCKET:?CodeBuild must supply the SAM artifact bucket}"
ASSET_HISTORY="s3://$SAM_ARTIFACT_BUCKET/lambda/ttrek-sh-assets/"
mkdir -p public/assets/versioned
aws s3 sync "$ASSET_HISTORY" public/assets/versioned/ --only-show-errors
ttrek run -script build-assets
npm test
python3 -m unittest discover -s tests -p 'test_lambda_versions.py'
(
  export TTREK_SITE_PREFIX="$TEST_PREFIX"
  export LD_LIBRARY_PATH="$TEST_PREFIX/lib:$TEST_PREFIX/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
  TCLSH="$TEST_PREFIX/bin/tclsh9.1"
  "$TCLSH" tests/all.tcl
  "$TCLSH" tests/homepage.test
  "$TCLSH" tests/accounts.test
  "$TCLSH" tests/static-content.test
  "$TCLSH" tests/content-images.test
  "$TCLSH" tests/content-images-build.test
  "$TCLSH" tests/browser-assets.test
  "$TCLSH" tests/config.test
  "$TCLSH" tests/lambda-config.test
  "$TCLSH" tests/telemetry-config.test
  "$TCLSH" tests/telemetry-startup.test
  "$TCLSH" tests/patch.test
  "$TCLSH" tests/email-queue.test
  "$TCLSH" tests/invoke-patch-local.test
  "$TCLSH" tests/telemetry.test
  "$TCLSH" tests/registry-metadata.test
  "$TCLSH" tests/recipe-downloads.test
  "$TCLSH" tests/package-tracker.test
  "$TCLSH" tests/stage-registry.test
  "$TCLSH" tests/build-lambda.test
  "$TCLSH" tests/search-store.test
  "$TCLSH" tests/telemetry-maintenance.test
  "$TCLSH" tests/installer.tcl
)
bash devops/generate-prod-config.sh
export TTREK_PRODUCTION_CONFIG="$SITE_ROOT/build/prod/config.ini"
# Build on AL2023 and skip tdevops' numeric glibc cutoff, which rejects backports.
ttrek run -script package-lambda -- --local-only
python3 devops/finalize-lambda.py dist/ttrek-sh.zip
"$TCLSH" tests/lambda-package.tcl dist/ttrek-sh.zip
sam validate --lint --template-file devops/sam-template.yaml
aws s3 sync public/assets/versioned/ "$ASSET_HISTORY" --only-show-errors
"$TCLSH" devops/upload-browser-assets.tcl "$TTREK_PRODUCTION_CONFIG"
