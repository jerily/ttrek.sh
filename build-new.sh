#!/bin/bash

set -eo pipefail # exit on error

#ROOT_BUILD_DIR=%s
#INSTALL_DIR=%s
#PROJECT_HOME=%s

#PROJECT_HOME="$(cd "$(dirname "$0")" && pwd)"

PROJECT_HOME="$(pwd)"

ROOT_BUILD_DIR="$PROJECT_HOME/build/build"
INSTALL_DIR="$PROJECT_HOME/build/install"

export PROJECT_HOME

DOWNLOAD_DIR="$ROOT_BUILD_DIR/download"
PATCH_DIR="$ROOT_BUILD_DIR/source"

mkdir -p "$DOWNLOAD_DIR"
mkdir -p "$PATCH_DIR"
mkdir -p "$INSTALL_DIR"

if [ -n "$TTREK_MAKE_THREADS" ]; then
    DEFAULT_THREADS="$TTREK_MAKE_THREADS"
else
    DEFAULT_THREADS="$(nproc 2>/dev/null)" \
        || DEFAULT_THREADS="$(sysctl -n hw.ncpu 2>/dev/null)" \
        || DEFAULT_THREADS="4"
fi

LD_LIBRARY_PATH="$INSTALL_DIR/lib"
PKG_CONFIG_PATH="$INSTALL_DIR/lib/pkgconfig"
export LD_LIBRARY_PATH
export PKG_CONFIG_PATH

PATH="$INSTALL_DIR/bin:$PATH"
export PATH

unpack() {
  local archive="$1"
  local output_directory="$2"

  # try with tar
  if tar -C "$output_directory" --strip-components 1 -xzf "$archive"; then
    return 0
  fi

  # try with unzip
  if unzip -d "$output_directory" "$archive"; then
    mv "$output_directory"/*/* "$output_directory"
    return 0
  fi
}
if [ "$1" = "-v" ] || [ "$1" = "-fail-verbose" ]; then
    TTREK_FAIL_VERBOSE=1
    shift
fi

init_tty() {
    [ "$IS_TTY" != '0' ] || return 0
    [ -z "$IS_TTY" ] && [ ! -t 1 ] && { IS_TTY=0; return 0; } || IS_TTY=0
    COLUMNS="$(tput cols 2>/dev/null || true)"
    case "$COLUMNS" in ''|*[!0-9]*) return;; esac
    BAR_LEN=$(( COLUMNS - 2 - 6 ))
    IS_TTY=1
    _G="$(tput setaf 2)"
    _R="$(tput setaf 9)"
    _A="$(tput setaf 8)"
    _T="$(tput sgr0)"
    echo
}

progress() {
    [ $IS_TTY -eq 1 ] || return 0
    printf '\033[1B\r\033[K'
    if [ $# -eq 2 ]; then
        PERCENT=$(( $1 * 100 / $2 ))
        BAR_LEN_CUR=$(( $1 * BAR_LEN / $2 ))
        printf '['
        [ "$BAR_LEN_CUR" -eq 0 ] || printf '=\033['$(( BAR_LEN_CUR - 1 ))';b'
        BAR_LEN_CUR=$(( BAR_LEN - BAR_LEN_CUR ))
        [ "$BAR_LEN_CUR" -eq 0 ] || printf -- '-\033['$(( BAR_LEN_CUR - 1 ))';b'
        printf '] %3s%%' "$PERCENT"
    fi
    [ $# -eq 1 ] || printf '\033[1A\r\033[K'
}

stage() {
    [ "$STAGE" != "$1" ] || return 0
    STAGE="$1"
    if [ "$STAGE" = ok ]; then
        progress
        STAGE_MSG=": ${_G}Done.${_T}"
        STAGE=5
    elif [ "$STAGE" = fail ]; then
        STAGE_MSG="${_R}Fail.${_T}"
        if [ $IS_TTY -eq 1 ]; then
            printf "\033[3D - $STAGE_MSG"
            unset STAGE_MSG
            progress -
        else
            STAGE_MSG=": $STAGE_MSG"
            progress
        fi
        STAGE=5
    else
        STAGE_MSG=" [${STAGE}/4]:"
        [ "$STAGE" != 1 ] || STAGE_MSG="$STAGE_MSG Getting sources..."
        [ "$STAGE" != 2 ] || STAGE_MSG="$STAGE_MSG Configuring sources..."
        [ "$STAGE" != 3 ] || STAGE_MSG="$STAGE_MSG Building..."
        [ "$STAGE" != 4 ] || STAGE_MSG="$STAGE_MSG Installing..."
        STAGE_TOT=$(( PKG_TOT * 5 ))
        STAGE_CUR=$(( (PKG_CUR - 1) * 5 + STAGE ))
        progress "$STAGE_CUR" "$STAGE_TOT"
    fi
    [ -z "$STAGE_MSG" ] || printf "Package [%s/%s]: %s v%s${_A};${_T} Stage%s" "$PKG_CUR" "$PKG_TOT" "$PACKAGE" "$VERSION" "$STAGE_MSG"
    if [ "$STAGE" = 5 ] || [ $IS_TTY -eq 0 ]; then echo; fi
    [ -z "$2" ] || exit "$2"
}

ok() { stage ok; }
fail() {
    R=$?
    stage fail
    echo "${_R}Failed command${_A}:${_T} $LATEST_COMMAND"
    if [ -n "$1" ] && [ -e "$1" ]; then
        if [ -z "$TTREK_FAIL_VERBOSE" ]; then
            echo "${_R}Check the details in the log file${_A}:${_T} $1"
        else
            echo "${_R}Log file${_A}:${_T} $1"
            cat "$1"
        fi
    fi
    echo
    exit $R
}
cmd() {
    LATEST_COMMAND="$@"
    "$@"
}

init_tty

PKG_CUR="1"
PKG_TOT="23"

PACKAGE='libvalkey'
VERSION='0.1.0'
SOURCE_DIR=''

ARCHIVE_FILE="${PACKAGE}-${VERSION}.archive"
BUILD_DIR="$ROOT_BUILD_DIR/build/${PACKAGE}-${VERSION}"
BUILD_LOG_DIR="$ROOT_BUILD_DIR/logs/${PACKAGE}-${VERSION}"

if [ -z "$SOURCE_DIR" ]; then
    SOURCE_DIR="$ROOT_BUILD_DIR/source/${PACKAGE}-${VERSION}"
fi

rm -rf "$SOURCE_DIR"
mkdir -p "$SOURCE_DIR"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
rm -rf "$BUILD_LOG_DIR"
mkdir -p "$BUILD_LOG_DIR"

stage 1
cmd curl -sL -o "$DOWNLOAD_DIR/$ARCHIVE_FILE" 'https://github.com/valkey-io/libvalkey/archive/1ce574c28ecf137329a410381ce03c453616a9f9.tar.gz' >"$BUILD_LOG_DIR/download.log" 2>&1 || fail "$BUILD_LOG_DIR/download.log"
stage 1
cmd unpack "$DOWNLOAD_DIR/$ARCHIVE_FILE" "$SOURCE_DIR" >"$BUILD_LOG_DIR/unpack.log" 2>&1 || fail "$BUILD_LOG_DIR/unpack.log"
cmd cd "$BUILD_DIR" || fail
stage 2
cmd cmake "$SOURCE_DIR" -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR" -DCMAKE_PREFIX_PATH="$INSTALL_DIR/" >"$BUILD_LOG_DIR/configure.log" 2>&1 || fail "$BUILD_LOG_DIR/configure.log"
stage 3
cmd make -j"$DEFAULT_THREADS" >"$BUILD_LOG_DIR/build.log" 2>&1 || fail "$BUILD_LOG_DIR/build.log"
stage 4
cmd make install >"$BUILD_LOG_DIR/install.log" 2>&1 || fail "$BUILD_LOG_DIR/install.log"
ok

PKG_CUR="2"
PKG_TOT="23"

PACKAGE='zlib'
VERSION='1.3.1'
SOURCE_DIR=''

ARCHIVE_FILE="${PACKAGE}-${VERSION}.archive"
BUILD_DIR="$ROOT_BUILD_DIR/build/${PACKAGE}-${VERSION}"
BUILD_LOG_DIR="$ROOT_BUILD_DIR/logs/${PACKAGE}-${VERSION}"

if [ -z "$SOURCE_DIR" ]; then
    SOURCE_DIR="$ROOT_BUILD_DIR/source/${PACKAGE}-${VERSION}"
fi

rm -rf "$SOURCE_DIR"
mkdir -p "$SOURCE_DIR"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
rm -rf "$BUILD_LOG_DIR"
mkdir -p "$BUILD_LOG_DIR"

stage 1
cmd curl -sL -o "$DOWNLOAD_DIR/$ARCHIVE_FILE" 'https://github.com/madler/zlib/releases/download/v1.3.1/zlib-1.3.1.tar.gz' >"$BUILD_LOG_DIR/download.log" 2>&1 || fail "$BUILD_LOG_DIR/download.log"
stage 1
cmd unpack "$DOWNLOAD_DIR/$ARCHIVE_FILE" "$SOURCE_DIR" >"$BUILD_LOG_DIR/unpack.log" 2>&1 || fail "$BUILD_LOG_DIR/unpack.log"
cmd cd "$BUILD_DIR" || fail
stage 2
cmd "$SOURCE_DIR/configure" '--'prefix="$INSTALL_DIR" >"$BUILD_LOG_DIR/configure.log" 2>&1 || fail "$BUILD_LOG_DIR/configure.log"
stage 3
cmd make -j"$DEFAULT_THREADS" >"$BUILD_LOG_DIR/build.log" 2>&1 || fail "$BUILD_LOG_DIR/build.log"
stage 4
cmd make install >"$BUILD_LOG_DIR/install.log" 2>&1 || fail "$BUILD_LOG_DIR/install.log"
ok

PKG_CUR="3"
PKG_TOT="23"

PACKAGE='protobuf'
VERSION='21.9.0'
SOURCE_DIR=''

ARCHIVE_FILE="${PACKAGE}-${VERSION}.archive"
BUILD_DIR="$ROOT_BUILD_DIR/build/${PACKAGE}-${VERSION}"
BUILD_LOG_DIR="$ROOT_BUILD_DIR/logs/${PACKAGE}-${VERSION}"

if [ -z "$SOURCE_DIR" ]; then
    SOURCE_DIR="$ROOT_BUILD_DIR/source/${PACKAGE}-${VERSION}"
fi

rm -rf "$SOURCE_DIR"
mkdir -p "$SOURCE_DIR"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
rm -rf "$BUILD_LOG_DIR"
mkdir -p "$BUILD_LOG_DIR"

stage 1
cmd curl -sL -o "$DOWNLOAD_DIR/$ARCHIVE_FILE" 'https://github.com/protocolbuffers/protobuf/archive/v21.9.zip' >"$BUILD_LOG_DIR/download.log" 2>&1 || fail "$BUILD_LOG_DIR/download.log"
stage 1
cmd unpack "$DOWNLOAD_DIR/$ARCHIVE_FILE" "$SOURCE_DIR" >"$BUILD_LOG_DIR/unpack.log" 2>&1 || fail "$BUILD_LOG_DIR/unpack.log"
cmd cd "$BUILD_DIR" || fail
stage 2
cmd cmake "$SOURCE_DIR" -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR" -DCMAKE_PREFIX_PATH="$INSTALL_DIR/" -D'BUILD_SHARED_LIBS'="ON" -D'CMAKE_BUILD_TYPE'="Release" -D'CMAKE_POSITION_INDEPENDENT_CODE'="ON" -D'CMAKE_CXX_FLAGS'="-fPIC" -D'protobuf_BUILD_TESTS'="OFF" -D'protobuf_BUILD_SHARED_LIBS'="ON" >"$BUILD_LOG_DIR/configure.log" 2>&1 || fail "$BUILD_LOG_DIR/configure.log"
stage 3
cmd make -j"$DEFAULT_THREADS" >"$BUILD_LOG_DIR/build.log" 2>&1 || fail "$BUILD_LOG_DIR/build.log"
stage 4
cmd make install >"$BUILD_LOG_DIR/install.log" 2>&1 || fail "$BUILD_LOG_DIR/install.log"
ok

PKG_CUR="4"
PKG_TOT="23"

PACKAGE='abseil-cpp'
VERSION='20230802.1.0'
SOURCE_DIR=''

ARCHIVE_FILE="${PACKAGE}-${VERSION}.archive"
BUILD_DIR="$ROOT_BUILD_DIR/build/${PACKAGE}-${VERSION}"
BUILD_LOG_DIR="$ROOT_BUILD_DIR/logs/${PACKAGE}-${VERSION}"

if [ -z "$SOURCE_DIR" ]; then
    SOURCE_DIR="$ROOT_BUILD_DIR/source/${PACKAGE}-${VERSION}"
fi

rm -rf "$SOURCE_DIR"
mkdir -p "$SOURCE_DIR"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
rm -rf "$BUILD_LOG_DIR"
mkdir -p "$BUILD_LOG_DIR"

stage 1
cmd curl -sL -o "$DOWNLOAD_DIR/$ARCHIVE_FILE" 'https://github.com/abseil/abseil-cpp/archive/refs/tags/20230802.1.tar.gz' >"$BUILD_LOG_DIR/download.log" 2>&1 || fail "$BUILD_LOG_DIR/download.log"
stage 1
cmd unpack "$DOWNLOAD_DIR/$ARCHIVE_FILE" "$SOURCE_DIR" >"$BUILD_LOG_DIR/unpack.log" 2>&1 || fail "$BUILD_LOG_DIR/unpack.log"
cmd cd "$BUILD_DIR" || fail
stage 2
cmd cmake "$SOURCE_DIR" -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR" -DCMAKE_PREFIX_PATH="$INSTALL_DIR/" -D'BUILD_SHARED_LIBS'="ON" -D'CMAKE_BUILD_TYPE'="Release" -D'CMAKE_CXX_STANDARD'="14" -D'ABSL_PROPAGATE_CXX_STD'="ON" >"$BUILD_LOG_DIR/configure.log" 2>&1 || fail "$BUILD_LOG_DIR/configure.log"
stage 3
cmd make -j"$DEFAULT_THREADS" >"$BUILD_LOG_DIR/build.log" 2>&1 || fail "$BUILD_LOG_DIR/build.log"
stage 4
cmd make install >"$BUILD_LOG_DIR/install.log" 2>&1 || fail "$BUILD_LOG_DIR/install.log"
ok

PKG_CUR="5"
PKG_TOT="23"

PACKAGE='openssl'
VERSION='3.2.1'
SOURCE_DIR=''

ARCHIVE_FILE="${PACKAGE}-${VERSION}.archive"
BUILD_DIR="$ROOT_BUILD_DIR/build/${PACKAGE}-${VERSION}"
BUILD_LOG_DIR="$ROOT_BUILD_DIR/logs/${PACKAGE}-${VERSION}"

if [ -z "$SOURCE_DIR" ]; then
    SOURCE_DIR="$ROOT_BUILD_DIR/source/${PACKAGE}-${VERSION}"
fi

rm -rf "$SOURCE_DIR"
mkdir -p "$SOURCE_DIR"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
rm -rf "$BUILD_LOG_DIR"
mkdir -p "$BUILD_LOG_DIR"

stage 1
cmd curl -sL -o "$DOWNLOAD_DIR/$ARCHIVE_FILE" 'https://www.openssl.org/source/openssl-3.2.1.tar.gz' >"$BUILD_LOG_DIR/download.log" 2>&1 || fail "$BUILD_LOG_DIR/download.log"
stage 1
cmd unpack "$DOWNLOAD_DIR/$ARCHIVE_FILE" "$SOURCE_DIR" >"$BUILD_LOG_DIR/unpack.log" 2>&1 || fail "$BUILD_LOG_DIR/unpack.log"
cmd cd "$SOURCE_DIR" || fail
stage 2
cmd "./Configure" '--'prefix="$INSTALL_DIR" '--''libdir'="lib" >"$BUILD_LOG_DIR/configure.log" 2>&1 || fail "$BUILD_LOG_DIR/configure.log"
stage 3
cmd make -j"$DEFAULT_THREADS" >"$BUILD_LOG_DIR/build.log" 2>&1 || fail "$BUILD_LOG_DIR/build.log"
stage 4
cmd make install >"$BUILD_LOG_DIR/install.log" 2>&1 || fail "$BUILD_LOG_DIR/install.log"
stage 4
cmd make "install_dev" >"$BUILD_LOG_DIR/install.log" 2>&1 || fail "$BUILD_LOG_DIR/install.log"
ok

PKG_CUR="6"
PKG_TOT="23"

PACKAGE='tcl'
VERSION='9.0.0-beta.3'
SOURCE_DIR=''

ARCHIVE_FILE="${PACKAGE}-${VERSION}.archive"
BUILD_DIR="$ROOT_BUILD_DIR/build/${PACKAGE}-${VERSION}"
BUILD_LOG_DIR="$ROOT_BUILD_DIR/logs/${PACKAGE}-${VERSION}"

if [ -z "$SOURCE_DIR" ]; then
    SOURCE_DIR="$ROOT_BUILD_DIR/source/${PACKAGE}-${VERSION}"
fi

rm -rf "$SOURCE_DIR"
mkdir -p "$SOURCE_DIR"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
rm -rf "$BUILD_LOG_DIR"
mkdir -p "$BUILD_LOG_DIR"

stage 1
cmd curl -sL -o "$DOWNLOAD_DIR/$ARCHIVE_FILE" 'https://github.com/tcltk/tcl/archive/refs/tags/core-9-0-b3.tar.gz' >"$BUILD_LOG_DIR/download.log" 2>&1 || fail "$BUILD_LOG_DIR/download.log"
stage 1
cmd unpack "$DOWNLOAD_DIR/$ARCHIVE_FILE" "$SOURCE_DIR" >"$BUILD_LOG_DIR/unpack.log" 2>&1 || fail "$BUILD_LOG_DIR/unpack.log"
cmd cd "$BUILD_DIR" || fail
stage 2
cmd "$SOURCE_DIR/unix/configure" '--'prefix="$INSTALL_DIR" >"$BUILD_LOG_DIR/configure.log" 2>&1 || fail "$BUILD_LOG_DIR/configure.log"
stage 3
cmd make -j"$DEFAULT_THREADS" >"$BUILD_LOG_DIR/build.log" 2>&1 || fail "$BUILD_LOG_DIR/build.log"
stage 4
cmd make install >"$BUILD_LOG_DIR/install.log" 2>&1 || fail "$BUILD_LOG_DIR/install.log"
ok

PKG_CUR="7"
PKG_TOT="23"

PACKAGE='curl'
VERSION='8.7.1'
SOURCE_DIR=''

ARCHIVE_FILE="${PACKAGE}-${VERSION}.archive"
BUILD_DIR="$ROOT_BUILD_DIR/build/${PACKAGE}-${VERSION}"
BUILD_LOG_DIR="$ROOT_BUILD_DIR/logs/${PACKAGE}-${VERSION}"

if [ -z "$SOURCE_DIR" ]; then
    SOURCE_DIR="$ROOT_BUILD_DIR/source/${PACKAGE}-${VERSION}"
fi

rm -rf "$SOURCE_DIR"
mkdir -p "$SOURCE_DIR"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
rm -rf "$BUILD_LOG_DIR"
mkdir -p "$BUILD_LOG_DIR"

stage 1
cmd curl -sL -o "$DOWNLOAD_DIR/$ARCHIVE_FILE" 'https://curl.se/download/curl-8.7.1.tar.gz' >"$BUILD_LOG_DIR/download.log" 2>&1 || fail "$BUILD_LOG_DIR/download.log"
stage 1
cmd unpack "$DOWNLOAD_DIR/$ARCHIVE_FILE" "$SOURCE_DIR" >"$BUILD_LOG_DIR/unpack.log" 2>&1 || fail "$BUILD_LOG_DIR/unpack.log"
cmd cd "$BUILD_DIR" || fail
stage 2
cmd "$SOURCE_DIR/configure" '--'prefix="$INSTALL_DIR" '--''with-openssl'="$INSTALL_DIR" '--''with-zlib'="$INSTALL_DIR" '--'"without-brotli" '--'"without-zstd" '--'"disable-ldap" '--'"disable-libidn2" '--'"enable-threads" >"$BUILD_LOG_DIR/configure.log" 2>&1 || fail "$BUILD_LOG_DIR/configure.log"
stage 3
cmd make -j"$DEFAULT_THREADS" >"$BUILD_LOG_DIR/build.log" 2>&1 || fail "$BUILD_LOG_DIR/build.log"
stage 4
cmd make install >"$BUILD_LOG_DIR/install.log" 2>&1 || fail "$BUILD_LOG_DIR/install.log"
ok

cat <<'__TTREK_PATCH_EOF__' > "$ROOT_BUILD_DIR/source/patch-tink-cc-2.1.1-fix-configure.diff"
diff -ur tink-cc-2.1.1/cmake/TinkWorkspace.cmake tink-cc/cmake/TinkWorkspace.cmake
--- tink-cc-2.1.1/cmake/TinkWorkspace.cmake	2023-11-30 18:26:00.000000000 -0500
+++ tink-cc/cmake/TinkWorkspace.cmake	2024-03-27 04:01:56.319966030 -0400
@@ -88,13 +88,15 @@
 else()
   # This is everything that needs to be done here. Abseil already defines its
   # targets, which gets linked in tink_cc_(library|test).
-  find_package(absl REQUIRED)
+  find_package(absl CONFIG REQUIRED)
+  add_library(absl::string_view ALIAS absl::strings)
 endif()
 
 # Don't fetch BoringSSL or look for OpenSSL if target `crypto` is already
 # defined.
 if (NOT TARGET crypto)
   if (NOT TINK_USE_SYSTEM_OPENSSL)
+    set(BUILD_SHARED_LIBS OFF)
     # Commit from Feb 15, 2023.
     # NOTE: This is one commit ahead of Bazel; the commit fixes a CMake issue,
     # which made build fail on CMake 3.10.
@@ -108,7 +110,9 @@
     # BoringSSL targets do not carry include directory info, this fixes it.
     target_include_directories(crypto PUBLIC
       "$<BUILD_INTERFACE:${boringssl_SOURCE_DIR}/src/include>")
+    set(BUILD_SHARED_LIBS ON)
   else()
+    list(APPEND CMAKE_FIND_ROOT_PATH "$ENV{OPENSSL_CUSTOM_ROOT_DIR}")
     # Support for ED25519 was added from 1.1.1.
     find_package(OpenSSL 1.1.1 REQUIRED)
     _create_interface_target(crypto OpenSSL::Crypto)
@@ -123,21 +127,29 @@
 set(RAPIDJSON_BUILD_EXAMPLES OFF CACHE BOOL "Tink dependency override" FORCE)
 set(RAPIDJSON_BUILD_TESTS OFF CACHE BOOL "Tink dependency override" FORCE)
 
-http_archive(
-  NAME rapidjson
-  URL https://github.com/Tencent/rapidjson/archive/v1.1.0.tar.gz
-  SHA256 bf7ced29704a1e696fbccf2a2b4ea068e7774fa37f6d7dd4039d0787f8bed98e
-)
-# Rapidjson is a header-only library with no explicit target. Here we create one.
-add_library(rapidjson INTERFACE)
-target_include_directories(rapidjson INTERFACE "${rapidjson_SOURCE_DIR}")
+if (NOT TINK_USE_INSTALLED_RAPIDJSON)
+  http_archive(
+    NAME rapidjson
+    URL https://github.com/Tencent/rapidjson/archive/v1.1.0.tar.gz
+    SHA256 bf7ced29704a1e696fbccf2a2b4ea068e7774fa37f6d7dd4039d0787f8bed98e
+  )
+  # Rapidjson is a header-only library with no explicit target. Here we create one.
+  add_library(rapidjson INTERFACE)
+  target_include_directories(rapidjson INTERFACE "${rapidjson_SOURCE_DIR}")
+else()
+  add_library(rapidjson INTERFACE)
+endif()
 
 set(protobuf_BUILD_TESTS OFF CACHE BOOL "Tink dependency override" FORCE)
 set(protobuf_BUILD_EXAMPLES OFF CACHE BOOL "Tink dependency override" FORCE)
-## Use protobuf X.21.9.
-http_archive(
-  NAME com_google_protobuf
-  URL https://github.com/protocolbuffers/protobuf/archive/v21.9.zip
-  SHA256 5babb8571f1cceafe0c18e13ddb3be556e87e12ceea3463d6b0d0064e6cc1ac3
-  CMAKE_SUBDIR cmake
-)
+if(NOT TINK_USE_INSTALLED_PROTOBUF)
+  ## Use protobuf X.21.9.
+  http_archive(
+    NAME com_google_protobuf
+    URL https://github.com/protocolbuffers/protobuf/archive/v21.9.zip
+    SHA256 5babb8571f1cceafe0c18e13ddb3be556e87e12ceea3463d6b0d0064e6cc1ac3
+    CMAKE_SUBDIR cmake
+  )
+else()
+  find_package(Protobuf REQUIRED)
+endif()
Only in tink-cc: cmake-build-debug
diff -ur tink-cc-2.1.1/CMakeLists.txt tink-cc/CMakeLists.txt
--- tink-cc-2.1.1/CMakeLists.txt	2023-11-30 18:26:00.000000000 -0500
+++ tink-cc/CMakeLists.txt	2024-03-26 05:21:39.194502916 -0400
@@ -1,6 +1,15 @@
 cmake_minimum_required(VERSION 3.13)
 project(Tink VERSION 2.1.1 LANGUAGES CXX)
 
+set(CMAKE_C_STANDARD   11)
+set(CMAKE_CXX_STANDARD 17)
+set(CMAKE_CXX_STANDARD_REQUIRED true)
+set(CMAKE_C_STANDARD_REQUIRED true)
+set(THREADS_PREFER_PTHREAD_FLAG ON)
+set(CMAKE_BUILD_TYPE Release)
+set(CMAKE_POSITION_INDEPENDENT_CODE ON)
+set(BUILD_SHARED_LIBS ON)
+
 list(APPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/cmake")
 
 option(TINK_BUILD_TESTS "Build Tink tests" OFF)
@@ -8,6 +17,16 @@
 option(TINK_USE_INSTALLED_ABSEIL "Build Tink linking to Abseil installed in the system" OFF)
 option(TINK_USE_INSTALLED_GOOGLETEST "Build Tink linking to GTest installed in the system" OFF)
 option(USE_ONLY_FIPS "Enables the FIPS only mode in Tink" OFF)
+option(TINK_BUILD_SHARED_LIB "Build libtink bundle it with the headers" OFF)
+option(TINK_USE_INSTALLED_PROTOBUF "Build Tink linking to Protobuf installed in the system" OFF)
+option(TINK_USE_INSTALLED_RAPIDJSON "Build Tink linking to Rapidjson installed in the system" OFF)
+
+if (TINK_BUILD_SHARED_LIB)
+  set(CMAKE_POSITION_INDEPENDENT_CODE ON CACHE BOOL "libtink override" FORCE)
+  include_directories("${CMAKE_INSTALL_PREFIX}")
+  link_directories("${CMAKE_INSTALL_PREFIX}/lib")
+  set(CMAKE_INSTALL_RPATH "${CMAKE_INSTALL_PREFIX}/lib" )
+endif()
 
 set(CPACK_GENERATOR TGZ)
 set(CPACK_PACKAGE_VERSION ${PROJECT_VERSION})
@@ -34,3 +53,25 @@
 
 add_subdirectory(tink)
 add_subdirectory(proto)
+
+if (TINK_BUILD_SHARED_LIB)
+  install(
+    DIRECTORY
+      "${CMAKE_CURRENT_SOURCE_DIR}/tink/"
+      "${TINK_GENFILE_DIR}/tink/"
+    DESTINATION "include/tink"
+    FILES_MATCHING PATTERN "*.h"
+  )
+
+  install(
+    DIRECTORY
+      "${TINK_GENFILE_DIR}/proto"
+    DESTINATION "include"
+    FILES_MATCHING PATTERN "*.h"
+  )
+
+#  export(EXPORT Tink FILE tinkConfig.cmake)
+#  install(FILES "${PROJECT_BINARY_DIR}/${PROJECT_NAME}Config.cmake"
+#    DESTINATION "${CMAKE_INSTALL_LIBDIR}/cmake/${PROJECT_NAME}"
+#  )
+endif()
Only in tink-cc: .idea
diff -ur tink-cc-2.1.1/tink/CMakeLists.txt tink-cc/tink/CMakeLists.txt
--- tink-cc-2.1.1/tink/CMakeLists.txt	2023-11-30 18:26:00.000000000 -0500
+++ tink-cc/tink/CMakeLists.txt	2024-03-26 05:26:12.669604059 -0400
@@ -25,9 +25,7 @@
 
 set(TINK_VERSION_H "${TINK_GENFILE_DIR}/tink/version.h")
 
-tink_cc_library(
-  NAME cc
-  SRCS
+set(TINK_PUBLIC_APIS
     aead.h
     aead_config.h
     aead_factory.h
@@ -73,8 +71,18 @@
     streaming_aead_key_templates.h
     streaming_mac.h
     tink_config.h
+    jwt/jwt_mac.h
+    jwt/jwt_public_key_sign.h
+    jwt/jwt_public_key_verify.h
+    jwt/jwt_signature_config.h
+    jwt/jwt_key_templates.h
+    jwt/jwt_validator.h
+    jwt/raw_jwt.h
+    jwt/jwk_set_converter.h
+    jwt/jwt_mac_config.h
     "${TINK_VERSION_H}"
-  DEPS
+)
+set(TINK_PUBLIC_API_DEPS
     tink::core::aead
     tink::core::binary_keyset_reader
     tink::core::binary_keyset_writer
@@ -139,6 +147,22 @@
     tink::util::validation
     tink::proto::config_cc_proto
     tink::proto::tink_cc_proto
+    tink::jwt::jwt_mac
+    tink::jwt::jwt_public_key_sign
+    tink::jwt::jwt_public_key_verify
+    tink::jwt::jwt_signature_config
+    tink::jwt::jwt_key_templates
+    tink::jwt::jwt_validator
+    tink::jwt::raw_jwt
+    tink::jwt::jwk_set_converter
+    tink::jwt::jwt_mac_config
+)
+tink_cc_library(
+  NAME cc
+  SRCS
+    ${TINK_PUBLIC_APIS}
+  DEPS
+    ${TINK_PUBLIC_API_DEPS}
   PUBLIC
 )
 
@@ -1135,3 +1159,39 @@
     absl::strings
     absl::string_view
 )
+
+if (TINK_BUILD_SHARED_LIB)
+  add_library(tink SHARED
+    ${TINK_PUBLIC_APIS}
+    version_script.lds
+    exported_symbols.lds
+  )
+  target_include_directories(tink PUBLIC ${TINK_INCLUDE_DIRS})
+  if (${CMAKE_SYSTEM_NAME} MATCHES "Darwin")
+  target_link_libraries(tink
+          PRIVATE
+      -Wl,-all_load
+      ${TINK_PUBLIC_API_DEPS}
+  )
+  else()
+  target_link_libraries(tink
+	  PRIVATE
+    -fuse-ld=gold  # GNU ld does not support ICF.
+    -Wl,--version-script="${CMAKE_CURRENT_SOURCE_DIR}/version_script.lds"
+    -Wl,--gc-sections
+    -Wl,--icf=all
+    -Wl,--strip-all
+  )
+  target_link_libraries(tink
+	  PRIVATE
+      -Wl,--whole-archive
+      ${TINK_PUBLIC_API_DEPS}
+      -Wl,--no-whole-archive
+  )
+  endif()
+  set_target_properties(tink PROPERTIES SOVERSION ${TINK_CC_VERSION_LABEL})
+
+  install(TARGETS tink EXPORT Tink LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR})
+endif()
+
+
diff -ur tink-cc-2.1.1/tink/internal/CMakeLists.txt tink-cc/tink/internal/CMakeLists.txt
--- tink-cc-2.1.1/tink/internal/CMakeLists.txt	2023-11-30 18:26:00.000000000 -0500
+++ tink-cc/tink/internal/CMakeLists.txt	2024-03-26 05:26:50.154575901 -0400
@@ -230,7 +230,7 @@
   DEPS
     tink::internal::key_info
     gmock
-    protobuf::libprotobuf-lite
+    protobuf::libprotobuf
     tink::proto::tink_cc_proto
 )
 
diff -ur tink-cc-2.1.1/tink/util/CMakeLists.txt tink-cc/tink/util/CMakeLists.txt
--- tink-cc-2.1.1/tink/util/CMakeLists.txt	2023-11-30 18:26:00.000000000 -0500
+++ tink-cc/tink/util/CMakeLists.txt	2024-03-26 05:27:23.275434360 -0400
@@ -226,7 +226,7 @@
   SRCS
     protobuf_helper.h
   DEPS
-    protobuf::libprotobuf-lite
+    protobuf::libprotobuf
 )
 
 tink_cc_library(

__TTREK_PATCH_EOF__

PKG_CUR="8"
PKG_TOT="23"

PACKAGE='tink-cc'
VERSION='2.1.1'
SOURCE_DIR=''

ARCHIVE_FILE="${PACKAGE}-${VERSION}.archive"
BUILD_DIR="$ROOT_BUILD_DIR/build/${PACKAGE}-${VERSION}"
BUILD_LOG_DIR="$ROOT_BUILD_DIR/logs/${PACKAGE}-${VERSION}"

if [ -z "$SOURCE_DIR" ]; then
    SOURCE_DIR="$ROOT_BUILD_DIR/source/${PACKAGE}-${VERSION}"
fi

rm -rf "$SOURCE_DIR"
mkdir -p "$SOURCE_DIR"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
rm -rf "$BUILD_LOG_DIR"
mkdir -p "$BUILD_LOG_DIR"

stage 1
cmd curl -sL -o "$DOWNLOAD_DIR/$ARCHIVE_FILE" 'https://github.com/tink-crypto/tink-cc/archive/refs/tags/v2.1.1.tar.gz' >"$BUILD_LOG_DIR/download.log" 2>&1 || fail "$BUILD_LOG_DIR/download.log"
stage 1
cmd unpack "$DOWNLOAD_DIR/$ARCHIVE_FILE" "$SOURCE_DIR" >"$BUILD_LOG_DIR/unpack.log" 2>&1 || fail "$BUILD_LOG_DIR/unpack.log"
stage 1
cd "$SOURCE_DIR" || fail
cat "$PATCH_DIR"/patch-"$PACKAGE"-"$VERSION"-'fix-configure.diff' | cmd patch -p'1' >"$BUILD_LOG_DIR"/patch-'fix-configure.diff'.log 2>&1 || fail "$BUILD_LOG_DIR"/patch-'fix-configure.diff'.log
cmd cd "$BUILD_DIR" || fail
stage 2
cmd cmake "$SOURCE_DIR" -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR" -DCMAKE_PREFIX_PATH="$INSTALL_DIR/" -D'TINK_BUILD_SHARED_LIB'="ON" -D'TINK_USE_INSTALLED_ABSEIL'="ON" -D'TINK_USE_SYSTEM_OPENSSL'="ON" -D'TINK_USE_INSTALLED_PROTOBUF'="ON" -D'TINK_USE_INSTALLED_RAPIDJSON'="OFF" -D'TINK_BUILD_TESTS'="OFF" -D'CMAKE_SKIP_RPATH'="ON" -D'CMAKE_BUILD_TYPE'="Release" >"$BUILD_LOG_DIR/configure.log" 2>&1 || fail "$BUILD_LOG_DIR/configure.log"
stage 3
cmd make -j"$DEFAULT_THREADS" >"$BUILD_LOG_DIR/build.log" 2>&1 || fail "$BUILD_LOG_DIR/build.log"
stage 4
cmd make install >"$BUILD_LOG_DIR/install.log" 2>&1 || fail "$BUILD_LOG_DIR/install.log"
ok

PKG_CUR="9"
PKG_TOT="23"

PACKAGE='sqlite3'
VERSION='3.45.3'
SOURCE_DIR=''

ARCHIVE_FILE="${PACKAGE}-${VERSION}.archive"
BUILD_DIR="$ROOT_BUILD_DIR/build/${PACKAGE}-${VERSION}"
BUILD_LOG_DIR="$ROOT_BUILD_DIR/logs/${PACKAGE}-${VERSION}"

if [ -z "$SOURCE_DIR" ]; then
    SOURCE_DIR="$ROOT_BUILD_DIR/source/${PACKAGE}-${VERSION}"
fi

rm -rf "$SOURCE_DIR"
mkdir -p "$SOURCE_DIR"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
rm -rf "$BUILD_LOG_DIR"
mkdir -p "$BUILD_LOG_DIR"

stage 1
cmd curl -sL -o "$DOWNLOAD_DIR/$ARCHIVE_FILE" 'https://sourceforge.net/projects/tcl/files/Tcl/9.0b3/sqlite3.45.3.tar.gz' >"$BUILD_LOG_DIR/download.log" 2>&1 || fail "$BUILD_LOG_DIR/download.log"
stage 1
cmd unpack "$DOWNLOAD_DIR/$ARCHIVE_FILE" "$SOURCE_DIR" >"$BUILD_LOG_DIR/unpack.log" 2>&1 || fail "$BUILD_LOG_DIR/unpack.log"
cmd cd "$BUILD_DIR" || fail
stage 2
cmd "$SOURCE_DIR/configure" '--'prefix="$INSTALL_DIR" '--''with-tcl'="$INSTALL_DIR/lib" >"$BUILD_LOG_DIR/configure.log" 2>&1 || fail "$BUILD_LOG_DIR/configure.log"
stage 3
cmd make -j"$DEFAULT_THREADS" >"$BUILD_LOG_DIR/build.log" 2>&1 || fail "$BUILD_LOG_DIR/build.log"
stage 4
cmd make install >"$BUILD_LOG_DIR/install.log" 2>&1 || fail "$BUILD_LOG_DIR/install.log"
ok

PKG_CUR="10"
PKG_TOT="23"

PACKAGE='tdom'
VERSION='0.9.4'
SOURCE_DIR=''

ARCHIVE_FILE="${PACKAGE}-${VERSION}.archive"
BUILD_DIR="$ROOT_BUILD_DIR/build/${PACKAGE}-${VERSION}"
BUILD_LOG_DIR="$ROOT_BUILD_DIR/logs/${PACKAGE}-${VERSION}"

if [ -z "$SOURCE_DIR" ]; then
    SOURCE_DIR="$ROOT_BUILD_DIR/source/${PACKAGE}-${VERSION}"
fi

rm -rf "$SOURCE_DIR"
mkdir -p "$SOURCE_DIR"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
rm -rf "$BUILD_LOG_DIR"
mkdir -p "$BUILD_LOG_DIR"

stage 1
cmd curl -sL -o "$DOWNLOAD_DIR/$ARCHIVE_FILE" 'http://tdom.org/downloads/tdom-0.9.4-src.tar.gz' >"$BUILD_LOG_DIR/download.log" 2>&1 || fail "$BUILD_LOG_DIR/download.log"
stage 1
cmd unpack "$DOWNLOAD_DIR/$ARCHIVE_FILE" "$SOURCE_DIR" >"$BUILD_LOG_DIR/unpack.log" 2>&1 || fail "$BUILD_LOG_DIR/unpack.log"
cmd cd "$SOURCE_DIR/unix" || fail
stage 2
cmd "../configure" '--'prefix="$INSTALL_DIR" '--''with-tcl'="$INSTALL_DIR/lib" >"$BUILD_LOG_DIR/configure.log" 2>&1 || fail "$BUILD_LOG_DIR/configure.log"
stage 3
cmd make -j"$DEFAULT_THREADS" >"$BUILD_LOG_DIR/build.log" 2>&1 || fail "$BUILD_LOG_DIR/build.log"
stage 4
cmd make install >"$BUILD_LOG_DIR/install.log" 2>&1 || fail "$BUILD_LOG_DIR/install.log"
ok

PKG_CUR="11"
PKG_TOT="23"

PACKAGE='thread'
VERSION='3.0.0-beta.4'
SOURCE_DIR=''

ARCHIVE_FILE="${PACKAGE}-${VERSION}.archive"
BUILD_DIR="$ROOT_BUILD_DIR/build/${PACKAGE}-${VERSION}"
BUILD_LOG_DIR="$ROOT_BUILD_DIR/logs/${PACKAGE}-${VERSION}"

if [ -z "$SOURCE_DIR" ]; then
    SOURCE_DIR="$ROOT_BUILD_DIR/source/${PACKAGE}-${VERSION}"
fi

rm -rf "$SOURCE_DIR"
mkdir -p "$SOURCE_DIR"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
rm -rf "$BUILD_LOG_DIR"
mkdir -p "$BUILD_LOG_DIR"

stage 1
cmd curl -sL -o "$DOWNLOAD_DIR/$ARCHIVE_FILE" 'https://sourceforge.net/projects/tcl/files/Tcl/9.0b3/thread3.0b4.tar.gz' >"$BUILD_LOG_DIR/download.log" 2>&1 || fail "$BUILD_LOG_DIR/download.log"
stage 1
cmd unpack "$DOWNLOAD_DIR/$ARCHIVE_FILE" "$SOURCE_DIR" >"$BUILD_LOG_DIR/unpack.log" 2>&1 || fail "$BUILD_LOG_DIR/unpack.log"
cmd cd "$BUILD_DIR" || fail
stage 2
cmd "$SOURCE_DIR/configure" '--'prefix="$INSTALL_DIR" '--''with-tcl'="$INSTALL_DIR/lib" >"$BUILD_LOG_DIR/configure.log" 2>&1 || fail "$BUILD_LOG_DIR/configure.log"
stage 3
cmd make -j"$DEFAULT_THREADS" >"$BUILD_LOG_DIR/build.log" 2>&1 || fail "$BUILD_LOG_DIR/build.log"
stage 4
cmd make install >"$BUILD_LOG_DIR/install.log" 2>&1 || fail "$BUILD_LOG_DIR/install.log"
ok

PKG_CUR="12"
PKG_TOT="23"

PACKAGE='tjson'
VERSION='1.0.25'
SOURCE_DIR=''

ARCHIVE_FILE="${PACKAGE}-${VERSION}.archive"
BUILD_DIR="$ROOT_BUILD_DIR/build/${PACKAGE}-${VERSION}"
BUILD_LOG_DIR="$ROOT_BUILD_DIR/logs/${PACKAGE}-${VERSION}"

if [ -z "$SOURCE_DIR" ]; then
    SOURCE_DIR="$ROOT_BUILD_DIR/source/${PACKAGE}-${VERSION}"
fi

rm -rf "$SOURCE_DIR"
mkdir -p "$SOURCE_DIR"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
rm -rf "$BUILD_LOG_DIR"
mkdir -p "$BUILD_LOG_DIR"

stage 1
cmd curl -sL -o "$DOWNLOAD_DIR/$ARCHIVE_FILE" 'https://github.com/jerily/tjson/archive/refs/tags/v1.0.25.tar.gz' >"$BUILD_LOG_DIR/download.log" 2>&1 || fail "$BUILD_LOG_DIR/download.log"
stage 1
cmd unpack "$DOWNLOAD_DIR/$ARCHIVE_FILE" "$SOURCE_DIR" >"$BUILD_LOG_DIR/unpack.log" 2>&1 || fail "$BUILD_LOG_DIR/unpack.log"
cmd cd "$BUILD_DIR" || fail
stage 2
cmd cmake "$SOURCE_DIR" -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR" -DCMAKE_PREFIX_PATH="$INSTALL_DIR/" -D'TCL_LIBRARY_DIR'="$INSTALL_DIR/lib" -D'TCL_INCLUDE_DIR'="$INSTALL_DIR/include" >"$BUILD_LOG_DIR/configure.log" 2>&1 || fail "$BUILD_LOG_DIR/configure.log"
stage 3
cmd make -j"$DEFAULT_THREADS" >"$BUILD_LOG_DIR/build.log" 2>&1 || fail "$BUILD_LOG_DIR/build.log"
stage 4
cmd make install >"$BUILD_LOG_DIR/install.log" 2>&1 || fail "$BUILD_LOG_DIR/install.log"
ok

PKG_CUR="13"
PKG_TOT="23"

PACKAGE='twebserver'
VERSION='1.47.53'
SOURCE_DIR=''

ARCHIVE_FILE="${PACKAGE}-${VERSION}.archive"
BUILD_DIR="$ROOT_BUILD_DIR/build/${PACKAGE}-${VERSION}"
BUILD_LOG_DIR="$ROOT_BUILD_DIR/logs/${PACKAGE}-${VERSION}"

if [ -z "$SOURCE_DIR" ]; then
    SOURCE_DIR="$ROOT_BUILD_DIR/source/${PACKAGE}-${VERSION}"
fi

rm -rf "$SOURCE_DIR"
mkdir -p "$SOURCE_DIR"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
rm -rf "$BUILD_LOG_DIR"
mkdir -p "$BUILD_LOG_DIR"

stage 1
cmd curl -sL -o "$DOWNLOAD_DIR/$ARCHIVE_FILE" 'https://github.com/jerily/twebserver/archive/refs/tags/v1.47.53.tar.gz' >"$BUILD_LOG_DIR/download.log" 2>&1 || fail "$BUILD_LOG_DIR/download.log"
stage 1
cmd unpack "$DOWNLOAD_DIR/$ARCHIVE_FILE" "$SOURCE_DIR" >"$BUILD_LOG_DIR/unpack.log" 2>&1 || fail "$BUILD_LOG_DIR/unpack.log"
cmd cd "$BUILD_DIR" || fail
stage 2
cmd cmake "$SOURCE_DIR" -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR" -DCMAKE_PREFIX_PATH="$INSTALL_DIR/" -D'TCL_LIBRARY_DIR'="$INSTALL_DIR/lib" -D'TCL_INCLUDE_DIR'="$INSTALL_DIR/include" >"$BUILD_LOG_DIR/configure.log" 2>&1 || fail "$BUILD_LOG_DIR/configure.log"
stage 3
cmd make >"$BUILD_LOG_DIR/build.log" 2>&1 || fail "$BUILD_LOG_DIR/build.log"
stage 4
cmd make install >"$BUILD_LOG_DIR/install.log" 2>&1 || fail "$BUILD_LOG_DIR/install.log"
ok

PKG_CUR="14"
PKG_TOT="23"

PACKAGE='valkey-tcl'
VERSION='1.0.0'
SOURCE_DIR=''

ARCHIVE_FILE="${PACKAGE}-${VERSION}.archive"
BUILD_DIR="$ROOT_BUILD_DIR/build/${PACKAGE}-${VERSION}"
BUILD_LOG_DIR="$ROOT_BUILD_DIR/logs/${PACKAGE}-${VERSION}"

if [ -z "$SOURCE_DIR" ]; then
    SOURCE_DIR="$ROOT_BUILD_DIR/source/${PACKAGE}-${VERSION}"
fi

rm -rf "$SOURCE_DIR"
mkdir -p "$SOURCE_DIR"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
rm -rf "$BUILD_LOG_DIR"
mkdir -p "$BUILD_LOG_DIR"

stage 1
cmd curl -sL -o "$DOWNLOAD_DIR/$ARCHIVE_FILE" 'https://github.com/jerily/valkey-tcl/archive/refs/tags/v1.0.0.tar.gz' >"$BUILD_LOG_DIR/download.log" 2>&1 || fail "$BUILD_LOG_DIR/download.log"
stage 1
cmd unpack "$DOWNLOAD_DIR/$ARCHIVE_FILE" "$SOURCE_DIR" >"$BUILD_LOG_DIR/unpack.log" 2>&1 || fail "$BUILD_LOG_DIR/unpack.log"
cmd cd "$BUILD_DIR" || fail
stage 2
cmd cmake "$SOURCE_DIR" -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR" -DCMAKE_PREFIX_PATH="$INSTALL_DIR/" -D'TCL_LIBRARY_DIR'="$INSTALL_DIR/lib" -D'TCL_INCLUDE_DIR'="$INSTALL_DIR/include" >"$BUILD_LOG_DIR/configure.log" 2>&1 || fail "$BUILD_LOG_DIR/configure.log"
stage 3
cmd make -j"$DEFAULT_THREADS" >"$BUILD_LOG_DIR/build.log" 2>&1 || fail "$BUILD_LOG_DIR/build.log"
stage 4
cmd make install >"$BUILD_LOG_DIR/install.log" 2>&1 || fail "$BUILD_LOG_DIR/install.log"
ok

PKG_CUR="15"
PKG_TOT="23"

PACKAGE='aws-sdk-cpp'
VERSION='1.11.157'
SOURCE_DIR=''

ARCHIVE_FILE="${PACKAGE}-${VERSION}.archive"
BUILD_DIR="$ROOT_BUILD_DIR/build/${PACKAGE}-${VERSION}"
BUILD_LOG_DIR="$ROOT_BUILD_DIR/logs/${PACKAGE}-${VERSION}"

if [ -z "$SOURCE_DIR" ]; then
    SOURCE_DIR="$ROOT_BUILD_DIR/source/${PACKAGE}-${VERSION}"
fi

rm -rf "$SOURCE_DIR"
mkdir -p "$SOURCE_DIR"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
rm -rf "$BUILD_LOG_DIR"
mkdir -p "$BUILD_LOG_DIR"

stage 1
cmd git -C "$SOURCE_DIR" clone 'https://github.com/aws/aws-sdk-cpp' --depth 1 --single-branch --branch '1.11.157' --recurse-submodules --shallow-submodules . >"$BUILD_LOG_DIR/download.log" 2>&1 || fail "$BUILD_LOG_DIR/download.log"
find "$SOURCE_DIR" -name '.git' -print0 | xargs -0 rm -rf || fail
cmd cd "$BUILD_DIR" || fail
stage 2
cmd cmake "$SOURCE_DIR" -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR" -DCMAKE_PREFIX_PATH="$INSTALL_DIR/" -D'BUILD_SHARED_LIBS'="ON" -D'CMAKE_BUILD_TYPE'="Release" -D'BUILD_ONLY'="s3;dynamodb;lambda;sqs;iam;transfer;sts;ssm;kms" -D'ENABLE_TESTING'="OFF" -D'AUTORUN_UNIT_TESTS'="OFF" >"$BUILD_LOG_DIR/configure.log" 2>&1 || fail "$BUILD_LOG_DIR/configure.log"
stage 3
cmd cmake --build "$BUILD_DIR" --parallel "$DEFAULT_THREADS" --config='Release' >"$BUILD_LOG_DIR/build.log" 2>&1 || fail "$BUILD_LOG_DIR/build.log"
stage 4
cmd cmake --install "$BUILD_DIR" --config='Release' >"$BUILD_LOG_DIR/install.log" 2>&1 || fail "$BUILD_LOG_DIR/install.log"
ok

PKG_CUR="16"
PKG_TOT="23"

PACKAGE='tink-tcl'
VERSION='20240704.0.0'
SOURCE_DIR=''

ARCHIVE_FILE="${PACKAGE}-${VERSION}.archive"
BUILD_DIR="$ROOT_BUILD_DIR/build/${PACKAGE}-${VERSION}"
BUILD_LOG_DIR="$ROOT_BUILD_DIR/logs/${PACKAGE}-${VERSION}"

if [ -z "$SOURCE_DIR" ]; then
    SOURCE_DIR="$ROOT_BUILD_DIR/source/${PACKAGE}-${VERSION}"
fi

rm -rf "$SOURCE_DIR"
mkdir -p "$SOURCE_DIR"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
rm -rf "$BUILD_LOG_DIR"
mkdir -p "$BUILD_LOG_DIR"

stage 1
cmd curl -sL -o "$DOWNLOAD_DIR/$ARCHIVE_FILE" 'https://github.com/jerily/tink-tcl/archive/refs/tags/v20240704.0.tar.gz' >"$BUILD_LOG_DIR/download.log" 2>&1 || fail "$BUILD_LOG_DIR/download.log"
stage 1
cmd unpack "$DOWNLOAD_DIR/$ARCHIVE_FILE" "$SOURCE_DIR" >"$BUILD_LOG_DIR/unpack.log" 2>&1 || fail "$BUILD_LOG_DIR/unpack.log"
cmd cd "$BUILD_DIR" || fail
stage 2
cmd cmake "$SOURCE_DIR" -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR" -DCMAKE_PREFIX_PATH="$INSTALL_DIR/" -D'TCL_LIBRARY_DIR'="$INSTALL_DIR/lib" -D'TCL_INCLUDE_DIR'="$INSTALL_DIR/include" -D'TINK_CPP_DIR'="$INSTALL_DIR" >"$BUILD_LOG_DIR/configure.log" 2>&1 || fail "$BUILD_LOG_DIR/configure.log"
stage 3
cmd make -j"$DEFAULT_THREADS" >"$BUILD_LOG_DIR/build.log" 2>&1 || fail "$BUILD_LOG_DIR/build.log"
stage 4
cmd make install >"$BUILD_LOG_DIR/install.log" 2>&1 || fail "$BUILD_LOG_DIR/install.log"
ok

PKG_CUR="17"
PKG_TOT="23"

PACKAGE='thtml'
VERSION='1.5.0'
SOURCE_DIR=''

ARCHIVE_FILE="${PACKAGE}-${VERSION}.archive"
BUILD_DIR="$ROOT_BUILD_DIR/build/${PACKAGE}-${VERSION}"
BUILD_LOG_DIR="$ROOT_BUILD_DIR/logs/${PACKAGE}-${VERSION}"

if [ -z "$SOURCE_DIR" ]; then
    SOURCE_DIR="$ROOT_BUILD_DIR/source/${PACKAGE}-${VERSION}"
fi

rm -rf "$SOURCE_DIR"
mkdir -p "$SOURCE_DIR"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
rm -rf "$BUILD_LOG_DIR"
mkdir -p "$BUILD_LOG_DIR"

stage 1
cmd git -C "$SOURCE_DIR" clone 'https://github.com/jerily/thtml' --depth 1 --single-branch . >"$BUILD_LOG_DIR/download.log" 2>&1 || fail "$BUILD_LOG_DIR/download.log"
find "$SOURCE_DIR" -name '.git' -print0 | xargs -0 rm -rf || fail
cmd cd "$BUILD_DIR" || fail
stage 2
cmd cmake "$SOURCE_DIR" -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR" -DCMAKE_PREFIX_PATH="$INSTALL_DIR/" -D'TCL_LIBRARY_DIR'="$INSTALL_DIR/lib" -D'TCL_INCLUDE_DIR'="$INSTALL_DIR/include" >"$BUILD_LOG_DIR/configure.log" 2>&1 || fail "$BUILD_LOG_DIR/configure.log"
stage 3
cmd make -j"$DEFAULT_THREADS" >"$BUILD_LOG_DIR/build.log" 2>&1 || fail "$BUILD_LOG_DIR/build.log"
stage 4
cmd make install >"$BUILD_LOG_DIR/install.log" 2>&1 || fail "$BUILD_LOG_DIR/install.log"
ok

PKG_CUR="18"
PKG_TOT="23"

PACKAGE='tratelimit'
VERSION='1.0.0'
SOURCE_DIR=''

ARCHIVE_FILE="${PACKAGE}-${VERSION}.archive"
BUILD_DIR="$ROOT_BUILD_DIR/build/${PACKAGE}-${VERSION}"
BUILD_LOG_DIR="$ROOT_BUILD_DIR/logs/${PACKAGE}-${VERSION}"

if [ -z "$SOURCE_DIR" ]; then
    SOURCE_DIR="$ROOT_BUILD_DIR/source/${PACKAGE}-${VERSION}"
fi

rm -rf "$SOURCE_DIR"
mkdir -p "$SOURCE_DIR"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
rm -rf "$BUILD_LOG_DIR"
mkdir -p "$BUILD_LOG_DIR"

stage 1
cmd git -C "$SOURCE_DIR" clone 'https://github.com/jerily/tratelimit' --depth 1 --single-branch . >"$BUILD_LOG_DIR/download.log" 2>&1 || fail "$BUILD_LOG_DIR/download.log"
find "$SOURCE_DIR" -name '.git' -print0 | xargs -0 rm -rf || fail
cmd cd "$SOURCE_DIR" || fail
stage 4
cmd make install "PREFIX"="$INSTALL_DIR" >"$BUILD_LOG_DIR/install.log" 2>&1 || fail "$BUILD_LOG_DIR/install.log"
ok

PKG_CUR="19"
PKG_TOT="23"

PACKAGE='treqmon'
VERSION='1.0.0'
SOURCE_DIR=''

ARCHIVE_FILE="${PACKAGE}-${VERSION}.archive"
BUILD_DIR="$ROOT_BUILD_DIR/build/${PACKAGE}-${VERSION}"
BUILD_LOG_DIR="$ROOT_BUILD_DIR/logs/${PACKAGE}-${VERSION}"

if [ -z "$SOURCE_DIR" ]; then
    SOURCE_DIR="$ROOT_BUILD_DIR/source/${PACKAGE}-${VERSION}"
fi

rm -rf "$SOURCE_DIR"
mkdir -p "$SOURCE_DIR"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
rm -rf "$BUILD_LOG_DIR"
mkdir -p "$BUILD_LOG_DIR"

stage 1
cmd git -C "$SOURCE_DIR" clone 'https://github.com/jerily/treqmon' --depth 1 --single-branch . >"$BUILD_LOG_DIR/download.log" 2>&1 || fail "$BUILD_LOG_DIR/download.log"
find "$SOURCE_DIR" -name '.git' -print0 | xargs -0 rm -rf || fail
cmd cd "$SOURCE_DIR" || fail
stage 4
cmd make install "PREFIX"="$INSTALL_DIR" >"$BUILD_LOG_DIR/install.log" 2>&1 || fail "$BUILD_LOG_DIR/install.log"
ok

PKG_CUR="20"
PKG_TOT="23"

PACKAGE='aws-sdk-tcl'
VERSION='1.0.10'
SOURCE_DIR=''

ARCHIVE_FILE="${PACKAGE}-${VERSION}.archive"
BUILD_DIR="$ROOT_BUILD_DIR/build/${PACKAGE}-${VERSION}"
BUILD_LOG_DIR="$ROOT_BUILD_DIR/logs/${PACKAGE}-${VERSION}"

if [ -z "$SOURCE_DIR" ]; then
    SOURCE_DIR="$ROOT_BUILD_DIR/source/${PACKAGE}-${VERSION}"
fi

rm -rf "$SOURCE_DIR"
mkdir -p "$SOURCE_DIR"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
rm -rf "$BUILD_LOG_DIR"
mkdir -p "$BUILD_LOG_DIR"

stage 1
cmd curl -sL -o "$DOWNLOAD_DIR/$ARCHIVE_FILE" 'https://github.com/jerily/aws-sdk-tcl/archive/refs/tags/v1.0.10.tar.gz' >"$BUILD_LOG_DIR/download.log" 2>&1 || fail "$BUILD_LOG_DIR/download.log"
stage 1
cmd unpack "$DOWNLOAD_DIR/$ARCHIVE_FILE" "$SOURCE_DIR" >"$BUILD_LOG_DIR/unpack.log" 2>&1 || fail "$BUILD_LOG_DIR/unpack.log"
cmd cd "$BUILD_DIR" || fail
stage 2
cmd cmake "$SOURCE_DIR" -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR" -DCMAKE_PREFIX_PATH="$INSTALL_DIR/" -D'TCL_LIBRARY_DIR'="$INSTALL_DIR/lib" -D'TCL_INCLUDE_DIR'="$INSTALL_DIR/include" -D'AWS_SDK_CPP_DIR'="$INSTALL_DIR" >"$BUILD_LOG_DIR/configure.log" 2>&1 || fail "$BUILD_LOG_DIR/configure.log"
stage 3
cmd make -j"$DEFAULT_THREADS" >"$BUILD_LOG_DIR/build.log" 2>&1 || fail "$BUILD_LOG_DIR/build.log"
stage 4
cmd make install >"$BUILD_LOG_DIR/install.log" 2>&1 || fail "$BUILD_LOG_DIR/install.log"
ok

PKG_CUR="21"
PKG_TOT="23"

PACKAGE='tsession'
VERSION='1.0.3'
SOURCE_DIR=''

ARCHIVE_FILE="${PACKAGE}-${VERSION}.archive"
BUILD_DIR="$ROOT_BUILD_DIR/build/${PACKAGE}-${VERSION}"
BUILD_LOG_DIR="$ROOT_BUILD_DIR/logs/${PACKAGE}-${VERSION}"

if [ -z "$SOURCE_DIR" ]; then
    SOURCE_DIR="$ROOT_BUILD_DIR/source/${PACKAGE}-${VERSION}"
fi

rm -rf "$SOURCE_DIR"
mkdir -p "$SOURCE_DIR"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
rm -rf "$BUILD_LOG_DIR"
mkdir -p "$BUILD_LOG_DIR"

stage 1
cmd curl -sL -o "$DOWNLOAD_DIR/$ARCHIVE_FILE" 'https://github.com/jerily/tsession/archive/refs/tags/v1.0.3.tar.gz' >"$BUILD_LOG_DIR/download.log" 2>&1 || fail "$BUILD_LOG_DIR/download.log"
stage 1
cmd unpack "$DOWNLOAD_DIR/$ARCHIVE_FILE" "$SOURCE_DIR" >"$BUILD_LOG_DIR/unpack.log" 2>&1 || fail "$BUILD_LOG_DIR/unpack.log"
cmd cd "$SOURCE_DIR" || fail
stage 4
cmd make install "PREFIX"="$INSTALL_DIR" >"$BUILD_LOG_DIR/install.log" 2>&1 || fail "$BUILD_LOG_DIR/install.log"
ok

PKG_CUR="22"
PKG_TOT="23"

PACKAGE='tconfig'
VERSION='1.0.0'
SOURCE_DIR=''

ARCHIVE_FILE="${PACKAGE}-${VERSION}.archive"
BUILD_DIR="$ROOT_BUILD_DIR/build/${PACKAGE}-${VERSION}"
BUILD_LOG_DIR="$ROOT_BUILD_DIR/logs/${PACKAGE}-${VERSION}"

if [ -z "$SOURCE_DIR" ]; then
    SOURCE_DIR="$ROOT_BUILD_DIR/source/${PACKAGE}-${VERSION}"
fi

rm -rf "$SOURCE_DIR"
mkdir -p "$SOURCE_DIR"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
rm -rf "$BUILD_LOG_DIR"
mkdir -p "$BUILD_LOG_DIR"

stage 1
cmd curl -sL -o "$DOWNLOAD_DIR/$ARCHIVE_FILE" 'https://github.com/jerily/tconfig/archive/refs/tags/v1.0.0.tar.gz' >"$BUILD_LOG_DIR/download.log" 2>&1 || fail "$BUILD_LOG_DIR/download.log"
stage 1
cmd unpack "$DOWNLOAD_DIR/$ARCHIVE_FILE" "$SOURCE_DIR" >"$BUILD_LOG_DIR/unpack.log" 2>&1 || fail "$BUILD_LOG_DIR/unpack.log"
cmd cd "$SOURCE_DIR" || fail
stage 4
cmd make install "PREFIX"="$INSTALL_DIR" >"$BUILD_LOG_DIR/install.log" 2>&1 || fail "$BUILD_LOG_DIR/install.log"
ok

PKG_CUR="23"
PKG_TOT="23"

PACKAGE='tsession-dynamodb'
VERSION='1.0.0'
SOURCE_DIR=''

ARCHIVE_FILE="${PACKAGE}-${VERSION}.archive"
BUILD_DIR="$ROOT_BUILD_DIR/build/${PACKAGE}-${VERSION}"
BUILD_LOG_DIR="$ROOT_BUILD_DIR/logs/${PACKAGE}-${VERSION}"

if [ -z "$SOURCE_DIR" ]; then
    SOURCE_DIR="$ROOT_BUILD_DIR/source/${PACKAGE}-${VERSION}"
fi

rm -rf "$SOURCE_DIR"
mkdir -p "$SOURCE_DIR"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
rm -rf "$BUILD_LOG_DIR"
mkdir -p "$BUILD_LOG_DIR"

stage 1
cmd git -C "$SOURCE_DIR" clone 'https://github.com/jerily/tsession-dynamodb.git' --depth 1 --single-branch . >"$BUILD_LOG_DIR/download.log" 2>&1 || fail "$BUILD_LOG_DIR/download.log"
find "$SOURCE_DIR" -name '.git' -print0 | xargs -0 rm -rf || fail
cmd cd "$SOURCE_DIR" || fail
stage 4
cmd make install "PREFIX"="$INSTALL_DIR" >"$BUILD_LOG_DIR/install.log" 2>&1 || fail "$BUILD_LOG_DIR/install.log"
ok
