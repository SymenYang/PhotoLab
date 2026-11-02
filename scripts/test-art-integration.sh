#!/bin/zsh
set -eu
cd "${0:A:h:h}"
: "${PHOTOLAB_TEST_IMAGE:?Set PHOTOLAB_TEST_IMAGE to a test JPEG}"
TEST_DIR="$(mktemp -d /private/tmp/photolab-art.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT
export PHOTOLAB_DATA_DIR="$TEST_DIR/data"
APP="$TEST_DIR/ArtTests.app/Contents"
mkdir -p "$APP/MacOS" "$APP/Resources"
cp -R build/PhotoLab.app/Contents/Resources/AI "$APP/Resources/"
cp AI/*.py "$APP/Resources/AI/"
xcrun swiftc -sdk "${PHOTOLAB_SDK:-$(xcrun --show-sdk-path)}" -swift-version 5 -parse-as-library -O -I Sources/CSQLite Sources/PhotoLab/{BackgroundTasks,Catalog,LibraryQuery,PreviewCache,PhotoEdits,PhotoDecoration,RedlampBackend,HEICHDRCompatibility,Media,ArtScoring,LibraryModel,SemanticSearch,ModelService,OneAheadPipeline}.swift Tests/ArtIntegration/main.swift -o "$APP/MacOS/Test"
"$APP/MacOS/Test" "$PHOTOLAB_TEST_IMAGE"
