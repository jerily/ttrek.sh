#!/bin/sh

set -e

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="$SELF_DIR/build/install"

LD_LIBRARY_PATH="$INSTALL_DIR/lib:$INSTALL_DIR/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export LD_LIBRARY_PATH

set -x

"$INSTALL_DIR/bin/tclsh9.1" "$SELF_DIR"/app.tcl
