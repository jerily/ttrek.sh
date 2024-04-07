#!/bin/bash

set -eo pipefail # exit on error

export SCRIPT_DIR=$1
INSTALL_DIR=$SCRIPT_DIR/local
echo "Installing to $INSTALL_DIR"

BUILD_DIR=$SCRIPT_DIR/build
mkdir -p $BUILD_DIR

BUILD_LOG_DIR=$BUILD_DIR/logs
mkdir -p $BUILD_LOG_DIR
export LD_LIBRARY_PATH=$INSTALL_DIR/lib:$INSTALL_DIR/lib64
export PKG_CONFIG_PATH=$INSTALL_DIR/lib/pkgconfig

# bcrypt-tcl
if true; then
  VERSION=2.0.0
  curl -L -o bcrypt-tcl-$VERSION.tar.gz --output-dir $BUILD_DIR https://github.com/jerily/bcrypt-tcl/archive/refs/tags/v2.0.0.tar.gz
  tar -xzf $BUILD_DIR/bcrypt-tcl-$VERSION.tar.gz -C $BUILD_DIR
  cd $BUILD_DIR/bcrypt-tcl-$VERSION
  mkdir build
  cd build
  cmake .. \
    -DTCL_LIBRARY_DIR=$INSTALL_DIR/lib \
    -DTCL_INCLUDE_DIR=$INSTALL_DIR/include \
    -DCMAKE_INSTALL_PREFIX=$INSTALL_DIR \
    -DCMAKE_PREFIX_PATH=$INSTALL_DIR/ > $BUILD_LOG_DIR/bcrypt-tcl-configure.log 2>&1
  make install > $BUILD_LOG_DIR/bcrypt-tcl-install.log 2>&1
fi