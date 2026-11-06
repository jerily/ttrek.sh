#!/bin/sh

set -e

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR=${TTREK_SITE_PREFIX:-${PROJECT_INSTALL_DIR:-"$SELF_DIR/ttrek-venv/local"}}

LD_LIBRARY_PATH="$INSTALL_DIR/lib:$INSTALL_DIR/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export LD_LIBRARY_PATH

set -x

exec "$INSTALL_DIR/bin/tclsh9.1" "$SELF_DIR"/app.tcl
