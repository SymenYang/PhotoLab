#!/bin/zsh
set -eu
cd "${0:A:h:h}"
TEST_DIR="$(mktemp -d /private/tmp/photolab-threshold-tests.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT
export PHOTOLAB_DATA_DIR="$TEST_DIR/data"
export PHOTOLAB_CACHE_DIR="$TEST_DIR/cache"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/private/tmp/photolab-module-cache}"
APP="$TEST_DIR/ThresholdTests.app/Contents"
mkdir -p "$APP/MacOS" "$APP/Resources"
cp -R build/PhotoLab.app/Contents/Resources/AI "$APP/Resources/"
cp AI/*.py "$APP/Resources/AI/"
xcrun swiftc -sdk "${PHOTOLAB_SDK:-$(xcrun --show-sdk-path)}" -swift-version 5 -parse-as-library -I Sources/CSQLite Sources/PhotoLab/{BackgroundTasks,Catalog,LibraryQuery,PreviewCache,PhotoEdits,PhotoDecoration,RedlampBackend,HEICHDRCompatibility,Media,ArtScoring,LibraryModel,SemanticSearch,ModelService,OneAheadPipeline}.swift Tests/SimilarityThreshold/main.swift -o "$APP/MacOS/tests"
"$APP/MacOS/tests"
