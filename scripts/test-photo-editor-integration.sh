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
# Exercise orchestration with deterministic inference, not the 16 GB live model.
unset PHOTOLAB_AI_CONFIG
cp Tests/color_worker_fixture.py "$TEST_DIR/Test.app/Contents/Resources/AI/color_worker.py"
print -r -- '[]' > "$TEST_DIR/Test.app/Contents/Resources/AI/models.json"
print -r -- '{"python":"/usr/bin/python3","jarvisModel":"/private/tmp"}' > "$TEST_DIR/Test.app/Contents/Resources/AI/config.json"
ln -s "$PWD/build/PhotoLab.app/Contents/Resources/ColorTools" "$TEST_DIR/Test.app/Contents/Resources/ColorTools"
ln -s "$PWD/.build/redlamp-native/Frameworks" "$TEST_DIR/Test.app/Contents/Frameworks"
ln -s "$PWD/Resources/Decorations" "$TEST_DIR/Test.app/Contents/Resources/Decorations"
SOURCES=(Sources/PhotoLab/*.swift)
SOURCES=(${SOURCES:#Sources/PhotoLab/PhotoLabApp.swift})
xcrun swiftc -sdk "${PHOTOLAB_SDK:-$(xcrun --show-sdk-path)}" -target arm64-apple-macosx26.3 -swift-version 5 -parse-as-library -O -whole-module-optimization -I Sources/CSQLite $SOURCES Tests/PhotoEditorIntegration/main.swift -o "$TEST_DIR/Test.app/Contents/MacOS/tests"
"$TEST_DIR/Test.app/Contents/MacOS/tests" "$PWD/test_photo/DSC00001.JPG" "$PWD/test_photo/DSC00001.ARW" "$@"
