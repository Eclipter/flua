#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p build/tests
swiftc Sources/Flua/Model.swift Sources/Flua/LibraryPaths.swift Tests/FluaTests/ModelTests.swift -o build/tests/model-tests
build/tests/model-tests
swiftc -target arm64-apple-macosx15.0 Sources/Flua/ScenePackage.swift Tests/FluaTests/ScenePackageTests.swift -o build/tests/package-tests
build/tests/package-tests
