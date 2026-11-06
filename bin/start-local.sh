#!/bin/sh
set -eu
SITE_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$SITE_ROOT/bin/site-env.sh"
PROJECT_HOME=$SITE_ROOT
TDEVOPS_PREFIX=$SITE_PREFIX
TCLSH=$SITE_TCLSH
export PROJECT_HOME TDEVOPS_PREFIX TCLSH
exec "$SITE_PREFIX/bin/tdevops" start-local "$@"
