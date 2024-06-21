#!/bin/sh

set -e

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="$SELF_DIR/build/install"

LD_LIBRARY_PATH="$SELF_DIR/build/install/lib"
export LD_LIBRARY_PATH

set -x

"$SELF_DIR/build/install/bin"/tclsh* "$SELF_DIR"/app.tcl
