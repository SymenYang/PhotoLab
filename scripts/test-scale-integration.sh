#!/bin/zsh
set -eu
cd "${0:A:h:h}"
BIN="$(mktemp -d /private/tmp/photolab-integration-bin.XXXXXX)/integration"
xcrun swiftc -sdk "${PHOTOLAB_SDK:-$(xcrun --show-sdk-path)}" -swift-version 5 -parse-as-library -O -I Sources/CSQLite Sources/PhotoLab/{BackgroundTasks,Catalog,LibraryQuery,PreviewCache,PhotoEdits,RedlampBackend,HEICHDRCompatibility,Media,ArtScoring,LibraryModel}.swift Tests/ScaleIntegration/main.swift -o "$BIN"
"$BIN"
