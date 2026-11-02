#!/bin/zsh
set -eu
cd "${0:A:h:h}"
TEST_DIR="$(mktemp -d /private/tmp/photolab-gestures.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT
export PHOTOLAB_DATA_DIR="$TEST_DIR/data"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/private/tmp/photolab-module-cache}"
export PHOTOLAB_CACHE_DIR="$TEST_DIR/cache"
xcrun swiftc -sdk "${PHOTOLAB_SDK:-$(xcrun --show-sdk-path)}" -swift-version 5 -parse-as-library -O -I Sources/CSQLite Sources/PhotoLab/{BackgroundTasks,Catalog,LibraryQuery,PreviewCache,PhotoEdits,PhotoDecoration,RedlampBackend,HEICHDRCompatibility,Media,ArtScoring,LibraryModel,SemanticSearch,ModelService,OneAheadPipeline}.swift Tests/PhotoNavigationGestures/main.swift -o "$TEST_DIR/tests"
"$TEST_DIR/tests"
