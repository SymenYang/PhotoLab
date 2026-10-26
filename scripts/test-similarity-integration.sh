#!/bin/zsh
set -eu
cd "${0:A:h:h}"
TEST_DIR="$(mktemp -d /private/tmp/photolab-similarity-integration.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT
export PHOTOLAB_DATA_DIR="$TEST_DIR/data"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/private/tmp/photolab-module-cache}"
export PHOTOLAB_CACHE_DIR="$TEST_DIR/cache"
APP="$TEST_DIR/SimilarityTests.app/Contents"
mkdir -p "$APP/MacOS" "$APP/Resources"
cp -R build/PhotoLab.app/Contents/Resources/AI "$APP/Resources/"
cp AI/*.py "$APP/Resources/AI/"
cp AI/worker.py "$APP/Resources/AI/worker.py"
xcrun swiftc -sdk "${PHOTOLAB_SDK:-$(xcrun --show-sdk-path)}" -swift-version 5 -parse-as-library -O -I Sources/CSQLite Sources/PhotoLab/{BackgroundTasks,Catalog,LibraryQuery,PreviewCache,PhotoEdits,RedlampBackend,HEICHDRCompatibility,Media,ArtScoring,LibraryModel,SemanticSearch,ModelService,OneAheadPipeline}.swift Tests/SimilarityIntegration/main.swift -o "$APP/MacOS/Test"
"$APP/MacOS/Test" "$PWD/test_photo/DSC00001.JPG"
