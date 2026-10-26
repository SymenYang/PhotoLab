#!/bin/zsh
set -eu
cd "${0:A:h:h}"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/private/tmp/photolab-module-cache}"
TEST_DIR="$(mktemp -d /private/tmp/photolab-filter-tests.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT
xcrun swiftc -sdk "${PHOTOLAB_SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}" -swift-version 5 -I Sources/CSQLite Sources/PhotoLab/{Catalog,LibraryQuery}.swift Tests/FilterRules/main.swift -o "$TEST_DIR/tests"
"$TEST_DIR/tests"
.ai-runtime/bin/python -B -m unittest discover -s AI -p 'test_fusion.py'
