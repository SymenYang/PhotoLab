#!/bin/zsh
set -eu
cd "${0:A:h:h}"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/private/tmp/photolab-color-module-cache}"
TEST_DIR="$(mktemp -d /private/tmp/photolab-color-tests.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT
export PHOTOLAB_DATA_DIR="$TEST_DIR/data"
unset PHOTOLAB_AI_CONFIG
APP="$TEST_DIR/Test.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/AI"
ln -s "$PWD/.build/redlamp-native/Frameworks" "$APP/Contents/Frameworks"
ln -s "$PWD/build/PhotoLab.app/Contents/Resources/ColorTools" "$APP/Contents/Resources/ColorTools"
cp Tests/color_worker_fixture.py "$APP/Contents/Resources/AI/color_worker.py"
cp AI/jarvis_prompt.py "$APP/Contents/Resources/AI/jarvis_prompt.py"
print -r -- '[]' > "$APP/Contents/Resources/AI/models.json"
print -r -- '{"python":"/usr/bin/python3","jarvisModel":"/private/tmp"}' > "$APP/Contents/Resources/AI/config.json"
if [[ "${1:-}" == "--real-ai" ]]; then
  cp AI/color_worker.py "$APP/Contents/Resources/AI/color_worker.py"
  cp build/PhotoLab.app/Contents/Resources/AI/config.json "$APP/Contents/Resources/AI/config.json"
fi
SOURCES=(Sources/PhotoLab/*.swift)
SOURCES=(${SOURCES:#Sources/PhotoLab/PhotoLabApp.swift})
xcrun swiftc -sdk "${PHOTOLAB_SDK:-$(xcrun --show-sdk-path)}" -target arm64-apple-macosx26.3 -swift-version 5 -parse-as-library -O -I Sources/CSQLite $SOURCES Tests/ColorControls/main.swift -o "$APP/Contents/MacOS/tests"
"$APP/Contents/MacOS/tests" "$@"
