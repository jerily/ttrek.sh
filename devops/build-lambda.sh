#!/usr/bin/env bash
set -euo pipefail

SITE_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
: "${CODEBUILD_SRC_DIR_PrivateRegistry:?CodeBuild must check out the PrivateRegistry secondary source}"
cd "$SITE_ROOT"

# The rebuilt glibc release targets glibc 2.28, compatible with AL2023's 2.34.
TTREK_BIN_DIR="$SITE_ROOT/build/ttrek"
mkdir -p "$TTREK_BIN_DIR"
# Override with an artifact built from ttrek's installation USE-flag changes.
TTREK_BINARY_S3_URI=${TTREK_BINARY_S3_URI:-s3://jerily-ttrek-app/ttrek/1.9.0/linux-amd64-glibc/ttrek}
aws s3 cp "$TTREK_BINARY_S3_URI" \
  "$TTREK_BIN_DIR/ttrek" --only-show-errors
chmod 0755 "$TTREK_BIN_DIR/ttrek"
"$TTREK_BIN_DIR/ttrek" self-update -version
export PATH="$TTREK_BIN_DIR:$PATH"
export JOBS=${TTREK_MAKE_THREADS:-4}

# Use the public checkout for dependency installation and build-time smoke tests.
export TTREK_PUBLIC_REGISTRY="$SITE_ROOT/build/public-registry"
ttrek sync "$TTREK_PUBLIC_REGISTRY"

# The private registry supplies build tools before the public package source.
# Include the failing recipe's log in CodeBuild output for diagnosis.
# Reusing a local prefix can retain excluded files. CodeBuild must package a
# fresh production installation.
if [[ -e "$SITE_ROOT/ttrek-venv/ttrek-manifest.json" ]]; then
  echo "Production packaging requires a fresh ttrek-venv; use a clean checkout." >&2
  exit 1
fi
ttrek use-flags add -local
ttrek install -y -fail-verbose -registry "$CODEBUILD_SRC_DIR_PrivateRegistry" \
  -registry "$TTREK_PUBLIC_REGISTRY"

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
"$TCLSH" tests/template-validation.test
"$TCLSH" tests/worker-startup.test
"$TCLSH" tests/profile.test
python3 -m unittest discover -s tests -p 'test_lambda_versions.py'
python3 -m unittest discover -s tests -p 'test_vpc_network.py'
python3 -m unittest discover -s tests -p 'test_finalize_lambda.py'
# Run SQLite-backed tests only when the existing installation provides SQLite.
# A broken installed driver must still fail the build.
HAS_SQLITE=$("$TCLSH" <<'TCL'
if {[catch {package require tdbc::sqlite3} message options]} {
    if {[dict get $options -errorcode] ne {TCL PACKAGE UNFOUND} ||
            [llength [package versions tdbc::sqlite3]]} {
        puts stderr $message
        exit 1
    }
    puts 0
} else {
    puts 1
}
TCL
)
if [[ "$HAS_SQLITE" == 1 ]]; then
  "$TCLSH" tests/all.tcl
  "$TCLSH" tests/homepage.test
  "$TCLSH" tests/accounts.test
  "$TCLSH" tests/static-content.test
  "$TCLSH" tests/content-images-build.test
  "$TCLSH" tests/telemetry-startup.test
  "$TCLSH" tests/patch.test
  "$TCLSH" tests/telemetry.test
  "$TCLSH" tests/registry-metadata.test
  "$TCLSH" tests/recipe-downloads.test
  "$TCLSH" tests/package-tracker.test
  "$TCLSH" tests/search-store.test
else
  echo "Skipping SQLite-backed tests: tdbc::sqlite3 is not installed."
fi
"$TCLSH" tests/content-images.test
"$TCLSH" tests/browser-assets.test
"$TCLSH" tests/config.test
"$TCLSH" tests/lambda-config.test
"$TCLSH" tests/telemetry-config.test
"$TCLSH" tests/email-queue.test
"$TCLSH" tests/invoke-patch-local.test
"$TCLSH" tests/build-lambda.test
"$TCLSH" tests/api-gateway.test
"$TCLSH" tests/telemetry-maintenance.test
"$TCLSH" tests/installer.tcl
bash devops/generate-prod-config.sh
export TTREK_PRODUCTION_CONFIG="$SITE_ROOT/build/prod/config.ini"
# Build on AL2023 and skip tdevops' numeric glibc cutoff, which rejects backports.
ttrek run -script package-lambda -- --local-only
sam validate --lint --template-file devops/sam-template.yaml
python3 devops/finalize-lambda.py dist/ttrek-sh.zip
"$TCLSH" tests/lambda-package.tcl dist/ttrek-sh.zip
aws s3 sync public/assets/versioned/ "$ASSET_HISTORY" --only-show-errors
"$TCLSH" devops/upload-browser-assets.tcl "$TTREK_PRODUCTION_CONFIG"
