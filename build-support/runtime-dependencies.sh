# Sourced by build.sh; all artifacts stay in its build/install prefix.

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

if [ ! -f "$INSTALL_DIR/lib/pkgconfig/valkey.pc" ]; then
    echo "Build libvalkey ..."
    fetch_source libvalkey-0.1.0 https://github.com/valkey-io/libvalkey/archive/1ce574c28ecf137329a410381ce03c453616a9f9.tar.gz
    cmake_install libvalkey-0.1.0 -DDISABLE_TESTS=ON
fi

if ! package_installed valkey; then
    echo "Build valkey-tcl ..."
    fetch_source valkey-tcl-1.0.0 https://github.com/jerily/valkey-tcl/archive/refs/tags/v1.0.0.tar.gz
    tcl_cmake_install valkey-tcl-1.0.0
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
        patch -d "$SOURCE_DIR/rapidjson-1.1.0" -p1 < "$SELF_DIR/build-support/rapidjson-1.1.0.patch"
        touch "$SOURCE_DIR/rapidjson-1.1.0/.patched"
    fi
    fetch_source tink-cc-2.1.1 https://github.com/tink-crypto/tink-cc/archive/refs/tags/v2.1.1.tar.gz
    if [ ! -f "$SOURCE_DIR/tink-cc-2.1.1/.patched" ]; then
        patch -d "$SOURCE_DIR/tink-cc-2.1.1" -p1 < "$SELF_DIR/build-support/tink-2.1.1.patch"
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
    fetch_source tink-tcl-20240704.0 https://github.com/jerily/tink-tcl/archive/refs/tags/v20240704.0.tar.gz
    if [ ! -f "$SOURCE_DIR/tink-tcl-20240704.0/.patched" ]; then
        patch -d "$SOURCE_DIR/tink-tcl-20240704.0" -p1 < "$SELF_DIR/build-support/tink-tcl-tcl91.patch"
        touch "$SOURCE_DIR/tink-tcl-20240704.0/.patched"
    fi
    tcl_cmake_install tink-tcl-20240704.0 -DTINK_CPP_DIR="$INSTALL_DIR"
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

if [ ! -f "$INSTALL_DIR/lib/cmake/AWSSDK/AWSSDKConfig.cmake" ]; then
    echo "Build AWS SDK for C++ ..."
    if [ ! -d "$SOURCE_DIR/aws-sdk-cpp-1.11.157/.git" ]; then
        git clone --depth 1 --branch 1.11.157 --single-branch \
            https://github.com/aws/aws-sdk-cpp "$SOURCE_DIR/aws-sdk-cpp-1.11.157"
    fi
    git -C "$SOURCE_DIR/aws-sdk-cpp-1.11.157" submodule update --init --recursive --depth 1
    cmake_install aws-sdk-cpp-1.11.157 \
        -DBUILD_ONLY='s3;dynamodb;lambda;sqs;iam;transfer;sts;ssm;kms' \
        -DENABLE_TESTING=OFF -DAUTORUN_UNIT_TESTS=OFF \
        -DOPENSSL_ROOT_DIR="$INSTALL_DIR"
fi

if ! package_installed awskms awsssm awsdynamodb; then
    echo "Build aws-sdk-tcl ..."
    fetch_source aws-sdk-tcl-1.0.10 https://github.com/jerily/aws-sdk-tcl/archive/refs/tags/v1.0.10.tar.gz
    tcl_cmake_install aws-sdk-tcl-1.0.10 -DAWS_SDK_CPP_DIR="$INSTALL_DIR"
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

install_tcl_package tratelimit-main tratelimit1.0.0 https://github.com/jerily/tratelimit/archive/refs/heads/main.tar.gz
install_tcl_package treqmon-main treqmon1.0.0 https://github.com/jerily/treqmon/archive/refs/heads/main.tar.gz
install_tcl_package tsession-1.0.3 tsession1.0.3 https://github.com/jerily/tsession/archive/refs/tags/v1.0.3.tar.gz
install_tcl_package tconfig-1.0.0 tconfig1.0.0 https://github.com/jerily/tconfig/archive/refs/tags/v1.0.0.tar.gz
install_tcl_package tsession-dynamodb-main tsession-dynamodb1.0.0 https://github.com/jerily/tsession-dynamodb/archive/refs/heads/main.tar.gz
