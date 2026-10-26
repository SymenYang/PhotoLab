#!/bin/zsh
set -eu
cd "${0:A:h:h}"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/private/tmp/photolab-module-cache}"
export PHOTOLAB_AI_CONFIG="${PHOTOLAB_AI_CONFIG:-$PWD/build/PhotoLab.app/Contents/Resources/AI/config.json}"
TEST_DIR="$(mktemp -d /private/tmp/photolab-redlamp-bin.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT
xcrun swiftc -sdk "${PHOTOLAB_SDK:-$(xcrun --show-sdk-path)}" -swift-version 5 -parse-as-library -O -I Sources/CSQLite Sources/PhotoLab/{Catalog,PhotoEdits,RedlampBackend}.swift Tests/RedlampTests/main.swift -o "$TEST_DIR/tests"
"$TEST_DIR/tests" "$@"
.ai-runtime/bin/python -m unittest discover -s Tests -p test_color_worker.py -v
