#!/bin/zsh
set -eu
cd "${0:A:h:h}"
TEST_DIR="$(mktemp -d /private/tmp/photolab-art-unit.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT
xcrun swiftc -sdk "${PHOTOLAB_SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}" -parse-as-library -I Sources/CSQLite Sources/PhotoLab/{Catalog,LibraryQuery,ArtScoring}.swift Tests/ArtScoringTests/main.swift -o "$TEST_DIR/tests"
"$TEST_DIR/tests"
