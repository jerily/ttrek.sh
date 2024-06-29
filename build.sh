#!/bin/sh

set -e

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_DIR="$SELF_DIR/build/source"
INSTALL_DIR="$SELF_DIR/build/install"
BUILD_DIR="$SELF_DIR/build/build"

DEBUG=1

if [ "$DEBUG" != 0 ]; then
    CFLAGS="-DPURIFY -fsanitize=address -g"
    LDFLAGS="-fsanitize=address"
    export CFLAGS
    export LDFLAGS
    SYMBOLS_FLAG="--enable-symbols=all"
else
    SYMBOLS_FLAG="--disable-symbols"
fi

mkdir -p "$BUILD_DIR" "$SOURCE_DIR"
cd "$BUILD_DIR"

echo "Start building ..."

if [ ! -e "$INSTALL_DIR"/bin/tclsh* ]; then
    echo "Build Tcl ..."
    if [ ! -e "$SOURCE_DIR"/tcl-* ]; then
        cd "$SOURCE_DIR"
        #curl -sL https://github.com/tcltk/tcl/archive/refs/tags/core-9-0-b1.tar.gz | tar zx
        curl -sL https://github.com/tcltk/tcl/archive/refs/tags/core-9-0-b2.tar.gz | tar zx
    fi
    mkdir -p "$BUILD_DIR"/tcl
    cd "$BUILD_DIR"/tcl
    "$SOURCE_DIR"/tcl-*/unix/configure $SYMBOL_FLAG --prefix="$INSTALL_DIR"
    make -j
    make install
fi

if [ ! -e "$INSTALL_DIR"/lib/tdom*/pkgIndex.tcl ]; then
    echo "Build tdom ..."
    if [ ! -e "$SOURCE_DIR"/tdom-* ]; then
        cd "$SOURCE_DIR"
        curl -sL http://tdom.org/index.html/tarball/trunk/tdom-trunk.tar.gz | tar zx
        #curl -sL http://tdom.org/downloads/tdom-0.9.3-src.tar.gz | tar zx
    fi
    mkdir -p "$BUILD_DIR"/tdom
    cd "$BUILD_DIR"/tdom
    "$SOURCE_DIR"/tdom-*/configure $SYMBOL_FLAG --with-tcl="$INSTALL_DIR"/lib --prefix="$INSTALL_DIR" --exec-prefix="$INSTALL_DIR"
    make -j
    make install
fi

if [ ! -e "$INSTALL_DIR"/lib/thtml*/pkgIndex.tcl ]; then
    echo "Build thtml ..."
    if [ ! -e "$SOURCE_DIR"/thtml-* ]; then
        cd "$SOURCE_DIR"
        curl -sL https://github.com/jerily/thtml/archive/refs/heads/main.tar.gz | tar zx
    fi
    mkdir -p "$BUILD_DIR"/thtml
    cd "$BUILD_DIR"/thtml
    cmake "$SOURCE_DIR"/thtml-* -DTCL_LIBRARY_DIR="$INSTALL_DIR"/lib -DTCL_INCLUDE_DIR="$INSTALL_DIR"/include -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR"
    make -j
    make install
fi

if [ ! -e "$INSTALL_DIR"/lib/tjson*/pkgIndex.tcl ]; then
    echo "Build tjson ..."
    if [ ! -e "$SOURCE_DIR"/tjson-* ]; then
        cd "$SOURCE_DIR"
        curl -sL https://github.com/jerily/tjson/archive/refs/heads/main.tar.gz | tar zx
    fi
    mkdir -p "$BUILD_DIR"/tjson
    cd "$BUILD_DIR"/tjson
    cmake "$SOURCE_DIR"/tjson-* -DTCL_LIBRARY_DIR="$INSTALL_DIR"/lib -DTCL_INCLUDE_DIR="$INSTALL_DIR"/include -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR"
    make -j
    make install
fi


if [ ! -e "$INSTALL_DIR"/bin/openssl* ]; then
    echo "Build openssl ..."
    if [ ! -e "$SOURCE_DIR"/openssl-* ]; then
        cd "$SOURCE_DIR"
        curl -sL https://www.openssl.org/source/openssl-3.2.1.tar.gz | tar zx
    fi
    cd "$SOURCE_DIR"/openssl-*
    CFLAGS= LDFLAGS= ./Configure --prefix="$INSTALL_DIR" no-docs
    make
    make install
fi

if [ ! -e "$INSTALL_DIR"/lib/twebserver*/pkgIndex.tcl ]; then
    echo "Build twebserver ..."
    if [ ! -e "$SOURCE_DIR"/twebserver-* ]; then
        cd "$SOURCE_DIR"
        curl -sL https://github.com/jerily/twebserver/archive/refs/heads/main.tar.gz | tar zx
    fi
    mkdir -p "$BUILD_DIR"/twebserver
    cd "$BUILD_DIR"/twebserver
    cmake "$SOURCE_DIR"/twebserver-* -DTCL_LIBRARY_DIR="$INSTALL_DIR"/lib -DTCL_INCLUDE_DIR="$INSTALL_DIR"/include -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR"
    make -j
    make install
fi

export LD_LIBRARY_PATH="$INSTALL_DIR"/lib
mkdir -p $SELF_DIR/certs/
cd $SELF_DIR/certs/
$INSTALL_DIR/bin/openssl req -x509 \
        -newkey rsa:4096 \
        -keyout key.pem \
        -out cert.pem \
        -sha256 \
        -days 3650 \
        -nodes \
        -subj "/C=CY/ST=Cyprus/L=Home/O=none/OU=CompanySectionName/CN=ttrek.sh/CN=get.ttrek.sh"

echo
echo "All done."
