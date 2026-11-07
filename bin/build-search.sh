#!/bin/sh
set -eu
SITE_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$SITE_ROOT/bin/site-env.sh"
exec "$SITE_TCLSH" "$SITE_ROOT/bin/build-search.tcl" "$@"
