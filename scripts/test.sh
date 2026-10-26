#!/bin/zsh
set -eu
cd "${0:A:h:h}"
TEST_BIN="$(mktemp -d /private/tmp/photolab-tests.XXXXXX)/catalog-tests"
swiftc -I Sources/CSQLite Sources/PhotoLab/Catalog.swift Tests/PhotoLabTests/CatalogTests.swift -o "$TEST_BIN"
"$TEST_BIN"
