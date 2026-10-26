#!/bin/zsh
set -eu
cd "${0:A:h:h}"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/private/tmp/photolab-module-cache}"
BIN="$(mktemp -d /private/tmp/photolab-similarity.XXXXXX)/tests"
xcrun swiftc -sdk "${PHOTOLAB_SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}" -swift-version 5 -O -I Sources/CSQLite Sources/PhotoLab/Catalog.swift Sources/PhotoLab/LibraryQuery.swift Tests/SimilarityTests/main.swift -o "$BIN"
"$BIN"
.ai-runtime/bin/python -m unittest discover -s AI -p 'test_similarity.py'
