#!/bin/zsh
set -eu
cd "${0:A:h:h}"
TEST_DIR="$(mktemp -d /private/tmp/photolab-filter-integration.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT
export PHOTOLAB_DATA_DIR="$TEST_DIR/data"
export PHOTOLAB_CACHE_DIR="$TEST_DIR/cache"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/private/tmp/photolab-module-cache}"
xcrun swiftc -sdk "${PHOTOLAB_SDK:-$(xcrun --show-sdk-path)}" -swift-version 5 -parse-as-library -I Sources/CSQLite Sources/PhotoLab/{BackgroundTasks,Catalog,LibraryQuery,PreviewCache,PhotoEdits,PhotoDecoration,RedlampBackend,HEICHDRCompatibility,Media,ArtScoring,LibraryModel,SemanticSearch,ModelService,OneAheadPipeline}.swift Tests/FilterRulesIntegration/main.swift -o "$TEST_DIR/tests"
"$TEST_DIR/tests"
