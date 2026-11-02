#!/bin/zsh
set -eu
cd "${0:A:h:h}"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/private/tmp/photolab-color-module-cache}"
TEST_DIR="$(mktemp -d /private/tmp/photolab-focus-tests.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT
export PHOTOLAB_DATA_DIR="$TEST_DIR/data"
export PHOTOLAB_CACHE_DIR="$TEST_DIR/cache"
APP="$TEST_DIR/Test.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
ln -s "$PWD/.build/redlamp-native/Frameworks" "$APP/Contents/Frameworks"
ln -s "$PWD/Resources/Decorations" "$APP/Contents/Resources/Decorations"
SOURCES=(Sources/PhotoLab/*.swift)
SOURCES=(${SOURCES:#Sources/PhotoLab/PhotoLabApp.swift})
xcrun swiftc -sdk "${PHOTOLAB_SDK:-$(xcrun --show-sdk-path)}" -target arm64-apple-macosx26.3 -swift-version 5 -parse-as-library -O -whole-module-optimization -I Sources/CSQLite $SOURCES Tests/FocusViewing/main.swift -o "$APP/Contents/MacOS/tests"
"$APP/Contents/MacOS/tests" "$@"
