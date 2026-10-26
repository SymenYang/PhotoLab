#!/bin/zsh
set -eu
cd "${0:A:h:h}"
TEST_DIR="$(mktemp -d /private/tmp/photolab-directory-bin.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT
xcrun swiftc -sdk "${PHOTOLAB_SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}" -swift-version 5 -O -I Sources/CSQLite Sources/PhotoLab/Catalog.swift Tests/DirectoryTests/main.swift -o "$TEST_DIR/tests"
"$TEST_DIR/tests"
