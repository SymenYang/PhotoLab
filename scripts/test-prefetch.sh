#!/bin/zsh
set -eu
cd "${0:A:h:h}"
PREFETCH_TEST_DIR="$(mktemp -d /private/tmp/photolab-prefetch-tests.XXXXXX)"
trap 'rm -rf "$PREFETCH_TEST_DIR"' EXIT
xcrun swiftc -sdk "${PHOTOLAB_SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}" -parse-as-library Sources/PhotoLab/OneAheadPipeline.swift Tests/PrefetchTests/main.swift -o "$PREFETCH_TEST_DIR/tests"
"$PREFETCH_TEST_DIR/tests"
