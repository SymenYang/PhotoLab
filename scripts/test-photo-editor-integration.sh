#!/bin/zsh
set -eu
cd "${0:A:h:h}"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/private/tmp/photolab-module-cache}"
TEST_DIR="$(mktemp -d /private/tmp/photolab-editor-bin.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT
export PHOTOLAB_DATA_DIR="$TEST_DIR/data"
mkdir -p "$TEST_DIR/Test.app/Contents/MacOS" "$TEST_DIR/Test.app/Contents/Resources"
cp -R build/PhotoLab.app/Contents/Resources/AI "$TEST_DIR/Test.app/Contents/Resources/"
cp AI/*.py "$TEST_DIR/Test.app/Contents/Resources/AI/"
xcrun swiftc -sdk "${PHOTOLAB_SDK:-$(xcrun --show-sdk-path)}" -swift-version 5 -parse-as-library -O -I Sources/CSQLite Sources/PhotoLab/{BackgroundTasks,Catalog,LibraryQuery,PreviewCache,PhotoEdits,RedlampBackend,HEICHDRCompatibility,Media,ArtScoring,LibraryModel,OneAheadPipeline,SemanticSearch,ModelService,AdaptiveCropSearch,AutoCrop,PhotoEditing}.swift Tests/PhotoEditorIntegration/main.swift -o "$TEST_DIR/Test.app/Contents/MacOS/tests"
"$TEST_DIR/Test.app/Contents/MacOS/tests" "$PWD/test_photo/DSC00001.JPG" "$PWD/test_photo/DSC00001.ARW" "$@"
