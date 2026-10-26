#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
TEST_DIR=$(mktemp -d /private/tmp/photolab-hdr-integration.XXXXXX)
trap 'rm -rf "$TEST_DIR"' EXIT
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/private/tmp/photolab-clang-cache}"
files=(Sources/PhotoLab/*.swift)
files=(${files:#Sources/PhotoLab/PhotoLabApp.swift})
xcrun swiftc -sdk "${PHOTOLAB_SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}" -swift-version 5 -parse-as-library -O -I Sources/CSQLite "${files[@]}" Tests/HEICHDRIntegration/main.swift -o "$TEST_DIR/tests"
"$TEST_DIR/tests"
