#!/bin/zsh
set -eu
cd "${0:A:h:h}"
BIN="$(mktemp -d /private/tmp/photolab-scale-bin.XXXXXX)/scale-tests"
xcrun swiftc -sdk "${PHOTOLAB_SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}" -swift-version 5 -O -I Sources/CSQLite Sources/PhotoLab/Catalog.swift Sources/PhotoLab/LibraryQuery.swift Sources/PhotoLab/PreviewCache.swift Tests/ScaleTests/main.swift -o "$BIN"
"$BIN"
