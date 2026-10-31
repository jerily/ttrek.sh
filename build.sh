#!/bin/sh

set -e

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_DIR="$SELF_DIR/build/source"
INSTALL_DIR="$SELF_DIR/build/install"
BUILD_DIR="$SELF_DIR/build/build"

TCL_VERSION=9.1.0
CJSON_VERSION=1.7.19
DEBUG=0
BUILD_JOBS=${TTREK_MAKE_THREADS:-4}

export PATH="$INSTALL_DIR/bin:$PATH"

export LD_LIBRARY_PATH="$INSTALL_DIR/lib:$INSTALL_DIR/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export PKG_CONFIG_PATH="$INSTALL_DIR/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

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

if [ ! -x "$INSTALL_DIR/bin/tclsh9.1" ]; then
    echo "Build Tcl $TCL_VERSION ..."
    if [ ! -d "$SOURCE_DIR/tcl$TCL_VERSION" ]; then
        curl -fLsS "https://prdownloads.sourceforge.net/tcl/tcl$TCL_VERSION-src.tar.gz" -o "$SOURCE_DIR/tcl$TCL_VERSION.tar.gz"
        tar -xzf "$SOURCE_DIR/tcl$TCL_VERSION.tar.gz" -C "$SOURCE_DIR"
    fi
    mkdir -p "$BUILD_DIR/tcl$TCL_VERSION"
    cd "$BUILD_DIR/tcl$TCL_VERSION"
    "$SOURCE_DIR/tcl$TCL_VERSION/unix/configure" "$SYMBOLS_FLAG" --prefix="$INSTALL_DIR"
    make -j"$BUILD_JOBS"
    # The Tcl release includes matching Thread and SQLite packages.
    make install
fi

if [ ! -e "$INSTALL_DIR/lib/pkgconfig/libcjson.pc" ]; then
    echo "Build cJSON ..."
    if [ ! -d "$SOURCE_DIR/cJSON-$CJSON_VERSION" ]; then
        curl -fLsS "https://github.com/DaveGamble/cJSON/archive/refs/tags/v$CJSON_VERSION.tar.gz" -o "$SOURCE_DIR/cJSON.tar.gz"
        tar -xzf "$SOURCE_DIR/cJSON.tar.gz" -C "$SOURCE_DIR"
    fi
    cmake -S "$SOURCE_DIR/cJSON-$CJSON_VERSION" -B "$BUILD_DIR/cJSON" \
        -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR" -DCMAKE_INSTALL_LIBDIR=lib \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DENABLE_CJSON_TEST=OFF -DBUILD_SHARED_LIBS=OFF -DCMAKE_POSITION_INDEPENDENT_CODE=ON
    cmake --build "$BUILD_DIR/cJSON" --parallel "$BUILD_JOBS"
    cmake --install "$BUILD_DIR/cJSON"
fi

if [ ! -e "$INSTALL_DIR/lib/jinja20.1.0/pkgIndex.tcl" ]; then
    echo "Build jinja2-tcl ..."
    if [ ! -d "$SOURCE_DIR/jinja2-tcl-main" ]; then
        curl -fLsS https://github.com/jerily/jinja2-tcl/archive/refs/heads/main.tar.gz -o "$SOURCE_DIR/jinja2-tcl.tar.gz"
        tar -xzf "$SOURCE_DIR/jinja2-tcl.tar.gz" -C "$SOURCE_DIR"
    fi
    cmake -S "$SOURCE_DIR/jinja2-tcl-main" -B "$BUILD_DIR/jinja2-tcl" \
        -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR" -DCMAKE_INSTALL_LIBDIR=lib \
        -DCMAKE_PREFIX_PATH="$INSTALL_DIR" \
        -DTCL_INCLUDE_PATH="$INSTALL_DIR/include" \
        -DTCL_STUB_LIBRARY="$INSTALL_DIR/lib/libtclstub.a" \
        -DTCL_TCLSH="$INSTALL_DIR/bin/tclsh9.1"
    cmake --build "$BUILD_DIR/jinja2-tcl" --parallel "$BUILD_JOBS"
    ctest --test-dir "$BUILD_DIR/jinja2-tcl" --output-on-failure
    cmake --install "$BUILD_DIR/jinja2-tcl"
fi

if [ ! -e "$INSTALL_DIR/lib/tjson1.0.26/pkgIndex.tcl" ]; then
    echo "Build tjson 1.0.26 ..."
    if [ ! -d "$SOURCE_DIR/tjson-1.0.26" ]; then
        curl -fLsS https://github.com/jerily/tjson/archive/refs/tags/v1.0.26.tar.gz -o "$SOURCE_DIR/tjson-1.0.26.tar.gz"
        tar -xzf "$SOURCE_DIR/tjson-1.0.26.tar.gz" -C "$SOURCE_DIR"
    fi
    cmake -S "$SOURCE_DIR/tjson-1.0.26" -B "$BUILD_DIR/tjson-1.0.26" \
        -DTCL_INCLUDE_PATH="$INSTALL_DIR/include" \
        -DTCL_STUB_LIBRARY="$INSTALL_DIR/lib/libtclstub.a" \
        -DTCL_TCLSH="$INSTALL_DIR/bin/tclsh9.1" \
        -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR"
    cmake --build "$BUILD_DIR/tjson-1.0.26" --parallel "$BUILD_JOBS"
    cmake --install "$BUILD_DIR/tjson-1.0.26"
fi


if [ ! -e "$INSTALL_DIR"/bin/openssl* ]; then
    echo "Build openssl ..."
    if [ ! -e "$SOURCE_DIR"/openssl-* ]; then
        cd "$SOURCE_DIR"
        curl -fLsS https://www.openssl.org/source/openssl-3.2.1.tar.gz | tar zx
    fi
    cd "$SOURCE_DIR"/openssl-*
    CFLAGS= LDFLAGS= ./Configure --prefix="$INSTALL_DIR" no-docs
    make -j"$BUILD_JOBS"
    make install
    make install_dev
fi

if [ ! -e "$INSTALL_DIR/lib/twebserver1.47.54/pkgIndex.tcl" ]; then
    echo "Build twebserver 1.47.54 ..."
    if [ ! -d "$SOURCE_DIR/twebserver-1.47.54" ]; then
        curl -fLsS https://github.com/jerily/twebserver/archive/refs/tags/v1.47.54.tar.gz -o "$SOURCE_DIR/twebserver-1.47.54.tar.gz"
        tar -xzf "$SOURCE_DIR/twebserver-1.47.54.tar.gz" -C "$SOURCE_DIR"
    fi
    cmake -S "$SOURCE_DIR/twebserver-1.47.54" -B "$BUILD_DIR/twebserver-1.47.54" \
        -DTCL_INCLUDE_PATH="$INSTALL_DIR/include" \
        -DTCL_STUB_LIBRARY="$INSTALL_DIR/lib/libtclstub.a" \
        -DTCL_TCLSH="$INSTALL_DIR/bin/tclsh9.1" \
        -DOPENSSL_ROOT_DIR="$INSTALL_DIR" -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR"
    cmake --build "$BUILD_DIR/twebserver-1.47.54" --parallel "$BUILD_JOBS"
    cmake --install "$BUILD_DIR/twebserver-1.47.54"
fi

. "$SELF_DIR/build-support/runtime-dependencies.sh"

"$INSTALL_DIR/bin/tclsh9.1" "$SELF_DIR/tests/runtime-packages.tcl"

if [ ! -e "$SELF_DIR/certs/cert.pem" ]; then
    echo "Generate certificates ..."
    export LD_LIBRARY_PATH="$INSTALL_DIR/lib:$INSTALL_DIR/lib64"
    mkdir -p "$SELF_DIR/certs"
    cd "$SELF_DIR/certs"
    "$INSTALL_DIR/bin/openssl" req -x509 \
        -newkey rsa:4096 \
        -keyout key.pem \
        -out cert.pem \
        -sha256 \
        -days 3650 \
        -nodes \
        -subj "/C=CY/ST=Cyprus/L=Home/O=none/OU=CompanySectionName/CN=ttrek.sh/CN=www.ttrek.sh"
fi

echo
echo "All done."
