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

# thtml
if true; then
  VERSION=1.0.13
  curl -L -o tjson-$VERSION.tar.gz --output-dir $BUILD_DIR https://github.com/jerily/tjson/archive/refs/tags/v1.0.13.tar.gz
  tar -xzvf $BUILD_DIR/tjson-$VERSION.tar.gz -C $BUILD_DIR
  cd $BUILD_DIR/tjson-$VERSION
  mkdir build
  cd build
  cmake .. \
    -DTCL_LIBRARY_DIR=$INSTALL_DIR/lib \
    -DTCL_INCLUDE_DIR=$INSTALL_DIR/include \
    -DCMAKE_INSTALL_PREFIX=$INSTALL_DIR \
    -DCMAKE_PREFIX_PATH=$INSTALL_DIR/ > $BUILD_LOG_DIR/tjson-configure.log 2>&1
  make install > $BUILD_LOG_DIR/tjson-install.log 2>&1
fi
