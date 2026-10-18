#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p build/tests
swiftc Sources/Flua/Model.swift Sources/Flua/LibraryPaths.swift Tests/FluaTests/ModelTests.swift -o build/tests/model-tests
build/tests/model-tests
swiftc -target arm64-apple-macosx27.0 Sources/Flua/ScenePackage.swift Tests/FluaTests/ScenePackageTests.swift -o build/tests/package-tests
build/tests/package-tests
swiftc -target arm64-apple-macosx27.0 Sources/Flua/Model.swift Sources/Flua/NativeWallpaperStore.swift Sources/Flua/NativeWallpaper.swift Tests/FluaTests/NativeWallpaperTests.swift -o build/tests/native-wallpaper-tests
build/tests/native-wallpaper-tests
swiftc -target arm64-apple-macosx27.0 Sources/Flua/AccentColor.swift Tests/FluaTests/AccentColorTests.swift -o build/tests/accent-color-tests
build/tests/accent-color-tests
