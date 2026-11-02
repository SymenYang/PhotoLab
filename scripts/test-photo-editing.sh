#!/bin/zsh
set -eu
cd "${0:A:h:h}"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/private/tmp/photolab-color-module-cache}"
TEST_DIR="$(mktemp -d /private/tmp/photolab-edit-bin.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT
export PHOTOLAB_DATA_DIR="$TEST_DIR/data"
SOURCES=(Sources/PhotoLab/*.swift)
SOURCES=(${SOURCES:#Sources/PhotoLab/PhotoLabApp.swift})
xcrun swiftc -sdk "${PHOTOLAB_SDK:-$(xcrun --show-sdk-path)}" -swift-version 5 -parse-as-library -O -whole-module-optimization -I Sources/CSQLite $SOURCES Tests/PhotoEditingTests/main.swift -o "$TEST_DIR/tests"
"$TEST_DIR/tests" "$PWD/test_photo/DSC00001.ARW" "$PWD/test_photo/B0001166.HEIC"
