#!/bin/zsh
set -eu
cd "${0:A:h:h}"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/private/tmp/photolab-module-cache}"
TEST_DIR="$(mktemp -d /private/tmp/photolab-adaptive.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT
xcrun swiftc -sdk "${PHOTOLAB_SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}" -parse-as-library -O Sources/PhotoLab/AdaptiveCropSearch.swift Tests/AdaptiveCrop/main.swift -o "$TEST_DIR/tests"
"$TEST_DIR/tests"
