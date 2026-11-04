#!/bin/sh

set -e

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_DIR="$SELF_DIR/build/source"
INSTALL_DIR="$SELF_DIR/build/install"
BUILD_DIR="$SELF_DIR/build/build"

TCL_VERSION=9.1.0
CJSON_VERSION=1.7.19
AWS_SDK_CPP_VERSION=1.11.921
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

# Runtime dependencies; artifacts stay in build/install.

fetch_source() (
    source_name=$1
    source_url=$2
    if [ ! -f "$SOURCE_DIR/$source_name/.unpacked" ]; then
        curl -fLsS --retry 3 "$source_url" -o "$SOURCE_DIR/$source_name.tar.gz"
        mkdir -p "$SOURCE_DIR/$source_name"
        tar -xzf "$SOURCE_DIR/$source_name.tar.gz" --strip-components=1 -C "$SOURCE_DIR/$source_name"
        touch "$SOURCE_DIR/$source_name/.unpacked"
    fi
)

cmake_install() (
    source_name=$1
    shift
    cmake -S "$SOURCE_DIR/$source_name" -B "$BUILD_DIR/$source_name" \
        -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR" -DCMAKE_INSTALL_LIBDIR=lib \
        -DCMAKE_PREFIX_PATH="$INSTALL_DIR" -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DCMAKE_CXX_STANDARD=17 \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DBUILD_SHARED_LIBS=ON "$@"
    cmake --build "$BUILD_DIR/$source_name" --parallel "$BUILD_JOBS"
    cmake --install "$BUILD_DIR/$source_name"
)

tcl_cmake_install() {
    cmake_install "$@" \
        -DTCL_LIBRARY_DIR="$INSTALL_DIR/lib" -DTCL_INCLUDE_DIR="$INSTALL_DIR/include" \
        -DTCL_LIBRARY="$INSTALL_DIR/lib/libtcl9.1.so" \
        -DTCL_INCLUDE_PATH="$INSTALL_DIR/include" \
        -DTCL_STUB_LIBRARY="$INSTALL_DIR/lib/libtclstub.a" \
        -DTCL_TCLSH="$INSTALL_DIR/bin/tclsh9.1"
}

package_installed() {
    "$INSTALL_DIR/bin/tclsh9.1" "$SELF_DIR/tests/runtime-packages.tcl" "$@" >/dev/null 2>&1
}

if ! package_installed ttrie; then
    echo "Build ttrie 0.1.1 ..."
    fetch_source ttrie-0.1.1 https://github.com/jerily/ttrie/releases/download/v0.1.1/ttrie-0.1.1.tar.gz
    tcl_cmake_install ttrie-0.1.1
    ctest --test-dir "$BUILD_DIR/ttrie-0.1.1" --output-on-failure
fi

if ! pkg-config --exact-version=0.5.0 valkey || ! pkg-config --exists valkey_tls; then
    echo "Build libvalkey ..."
    fetch_source libvalkey-0.5.0 https://github.com/valkey-io/libvalkey/archive/refs/tags/0.5.0.tar.gz
    cmake_install libvalkey-0.5.0 -DDISABLE_TESTS=ON -DENABLE_TLS=ON -DOPENSSL_ROOT_DIR="$INSTALL_DIR"
fi

if ! package_installed valkey; then
    echo "Build valkey-tcl ..."
    fetch_source valkey-tcl-1.0.3 https://github.com/jerily/valkey-tcl/archive/refs/tags/v1.0.3.tar.gz
    tcl_cmake_install valkey-tcl-1.0.3 -DENABLE_SSL=ON -DOPENSSL_ROOT_DIR="$INSTALL_DIR"
fi

if [ ! -f "$INSTALL_DIR/lib/pkgconfig/protobuf.pc" ]; then
    echo "Build protobuf ..."
    fetch_source protobuf-21.9 https://github.com/protocolbuffers/protobuf/archive/refs/tags/v21.9.tar.gz
    cmake_install protobuf-21.9 -Dprotobuf_BUILD_TESTS=OFF -Dprotobuf_BUILD_SHARED_LIBS=ON
fi

if [ ! -f "$INSTALL_DIR/lib/pkgconfig/absl_status.pc" ]; then
    echo "Build Abseil ..."
    fetch_source abseil-20230802.1 https://github.com/abseil/abseil-cpp/archive/refs/tags/20230802.1.tar.gz
    cmake_install abseil-20230802.1 -DABSL_PROPAGATE_CXX_STD=ON -DABSL_BUILD_TESTING=OFF
fi

if [ ! -f "$INSTALL_DIR/lib/libtink.so" ]; then
    echo "Build Tink ..."
    fetch_source rapidjson-1.1.0 https://github.com/Tencent/rapidjson/archive/refs/tags/v1.1.0.tar.gz
    if [ ! -f "$SOURCE_DIR/rapidjson-1.1.0/.patched" ]; then
        patch -d "$SOURCE_DIR/rapidjson-1.1.0" -p1 < "$SELF_DIR/registry/tink-cc/2.1.1/rapidjson-1.1.0.diff"
        touch "$SOURCE_DIR/rapidjson-1.1.0/.patched"
    fi
    fetch_source tink-cc-2.1.1 https://github.com/tink-crypto/tink-cc/archive/refs/tags/v2.1.1.tar.gz
    if [ ! -f "$SOURCE_DIR/tink-cc-2.1.1/.patched" ]; then
        patch -d "$SOURCE_DIR/tink-cc-2.1.1" -p1 < "$SELF_DIR/registry/tink-cc/2.1.1/fix-configure.diff"
        touch "$SOURCE_DIR/tink-cc-2.1.1/.patched"
    fi
    cmake_install tink-cc-2.1.1 \
        -DTINK_BUILD_SHARED_LIB=ON -DTINK_BUILD_TESTS=OFF \
        -DTINK_USE_INSTALLED_ABSEIL=ON -DTINK_USE_SYSTEM_OPENSSL=ON \
        -DTINK_USE_INSTALLED_PROTOBUF=ON -DTINK_USE_INSTALLED_RAPIDJSON=OFF \
        -DFETCHCONTENT_SOURCE_DIR_RAPIDJSON="$SOURCE_DIR/rapidjson-1.1.0" \
        -DOPENSSL_ROOT_DIR="$INSTALL_DIR"
fi

if ! package_installed tink; then
    echo "Build tink-tcl ..."
    fetch_source tink-tcl-20240704.0.1 https://github.com/jerily/tink-tcl/archive/refs/tags/v20240704.0.1.tar.gz
    tcl_cmake_install tink-tcl-20240704.0.1 -DTINK_CPP_DIR="$INSTALL_DIR"
fi

if [ ! -f "$INSTALL_DIR/lib/pkgconfig/libcurl.pc" ]; then
    echo "Build curl ..."
    fetch_source curl-8.7.1 https://curl.se/download/curl-8.7.1.tar.gz
    (
        mkdir -p "$BUILD_DIR/curl-8.7.1"
        cd "$BUILD_DIR/curl-8.7.1"
        "$SOURCE_DIR/curl-8.7.1/configure" --prefix="$INSTALL_DIR" \
            --with-openssl="$INSTALL_DIR" --without-brotli --without-zstd \
            --disable-ldap --without-libidn2
        make -j"$BUILD_JOBS"
        make install
    )
fi

AWS_SDK_CPP_REBUILT=0
if ! grep -q "^set(PACKAGE_VERSION \"$AWS_SDK_CPP_VERSION\")$" \
        "$INSTALL_DIR/lib/cmake/AWSSDK/AWSSDKConfigVersion.cmake" 2>/dev/null; then
    echo "Build AWS SDK for C++ ..."
    if [ ! -d "$SOURCE_DIR/aws-sdk-cpp-$AWS_SDK_CPP_VERSION/.git" ]; then
        git clone --depth 1 --branch "$AWS_SDK_CPP_VERSION" --single-branch \
            https://github.com/aws/aws-sdk-cpp "$SOURCE_DIR/aws-sdk-cpp-$AWS_SDK_CPP_VERSION"
    fi
    git -C "$SOURCE_DIR/aws-sdk-cpp-$AWS_SDK_CPP_VERSION" submodule update --init --recursive --depth 1
    cmake_install "aws-sdk-cpp-$AWS_SDK_CPP_VERSION" \
        -DCMAKE_MODULE_PATH="$SOURCE_DIR/aws-sdk-cpp-$AWS_SDK_CPP_VERSION/crt/aws-crt-cpp/crt/aws-c-common/cmake" \
        -DBUILD_ONLY='s3;dynamodb;lambda;sqs;iam;transfer;sts;ssm;kms' \
        -DENABLE_TESTING=OFF -DAUTORUN_UNIT_TESTS=OFF \
        -DOPENSSL_ROOT_DIR="$INSTALL_DIR"
    AWS_SDK_CPP_REBUILT=1
fi

if [ "$AWS_SDK_CPP_REBUILT" = 1 ] || ! package_installed awss3 awskms awsssm awsdynamodb; then
    echo "Build aws-sdk-tcl ..."
    fetch_source aws-sdk-tcl-1.0.12 https://github.com/jerily/aws-sdk-tcl/archive/refs/tags/v1.0.12.tar.gz
    tcl_cmake_install aws-sdk-tcl-1.0.12 -DAWS_SDK_CPP_DIR="$INSTALL_DIR"
fi

install_tcl_package() (
    source_name=$1
    package_name=$2
    source_url=$3
    if [ ! -f "$INSTALL_DIR/lib/$package_name/pkgIndex.tcl" ]; then
        echo "Install $source_name ..."
        fetch_source "$source_name" "$source_url"
        make -C "$SOURCE_DIR/$source_name" install PREFIX="$INSTALL_DIR"
    fi
)

install_tcl_package tratelimit-1.0.1 tratelimit1.0.1 https://github.com/jerily/tratelimit/archive/refs/tags/v1.0.1.tar.gz
install_tcl_package treqmon-2.0.0 treqmon2.0.0 https://github.com/jerily/treqmon/archive/refs/tags/v2.0.0.tar.gz
install_tcl_package tsession-1.0.3 tsession1.0.3 https://github.com/jerily/tsession/archive/refs/tags/v1.0.3.tar.gz
install_tcl_package tconfig-1.0.0 tconfig1.0.0 https://github.com/jerily/tconfig/archive/refs/tags/v1.0.0.tar.gz
install_tcl_package tsession-dynamodb-main tsession-dynamodb1.0.0 https://github.com/jerily/tsession-dynamodb/archive/refs/heads/main.tar.gz

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
