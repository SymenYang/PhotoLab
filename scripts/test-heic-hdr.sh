#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
TEST_DIR=$(mktemp -d /private/tmp/photolab-heic-hdr.XXXXXX)
trap 'rm -rf "$TEST_DIR"' EXIT
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/private/tmp/photolab-clang-cache}"
xcrun swiftc -sdk "${PHOTOLAB_SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}" -swift-version 5 -parse-as-library -O Sources/PhotoLab/HEICHDRCompatibility.swift Tests/HEICHDRCompatibility/main.swift -o "$TEST_DIR/tests"
"$TEST_DIR/tests" "$@"
