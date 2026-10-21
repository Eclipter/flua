#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
python3 Tests/Scripts/SmokeTests.py
mkdir -p build/tests
swiftc Sources/Flua/Model.swift Sources/Flua/LibraryPaths.swift Tests/FluaTests/ModelTests.swift -o build/tests/model-tests
build/tests/model-tests
swiftc -parse-as-library -target arm64-apple-macosx27.0 Sources/Flua/Model.swift Sources/Flua/LibraryPaths.swift Sources/Flua/Engine.swift Sources/Flua/NativeWallpaperStore.swift Sources/Flua/NativeWallpaper.swift Sources/Flua/MediaFacts.swift Sources/Flua/SceneView.swift Sources/Flua/ScenePreviewRenderer.swift Sources/Flua/SceneDrawing.swift Sources/Flua/ScenePackage.swift Sources/Flua/Library.swift Tests/FluaTests/ClearFiltersSortTests.swift -o build/tests/clear-filters-sort-tests
build/tests/clear-filters-sort-tests
swiftc -target arm64-apple-macosx27.0 Sources/Flua/ScenePackage.swift Tests/FluaTests/ScenePackageTests.swift -o build/tests/package-tests
build/tests/package-tests
swiftc -target arm64-apple-macosx27.0 Sources/Flua/Model.swift Sources/Flua/NativeWallpaperStore.swift Sources/Flua/NativeWallpaper.swift Tests/FluaTests/NativeWallpaperTests.swift -o build/tests/native-wallpaper-tests
build/tests/native-wallpaper-tests
swiftc -target arm64-apple-macosx27.0 Sources/Flua/AccentColor.swift Tests/FluaTests/AccentColorTests.swift -o build/tests/accent-color-tests
build/tests/accent-color-tests
swiftc -parse-as-library -target arm64-apple-macosx27.0 Tests/FluaTests/FocusTests.swift -o build/tests/focus-tests
build/tests/focus-tests
swiftc -parse-as-library -target arm64-apple-macosx27.0 Tests/FluaTests/InstallerTests.swift -o build/tests/installer-tests
build/tests/installer-tests
swiftc -O -target arm64-apple-macosx27.0 Sources/Flua/SceneDrawing.swift Tests/FluaTests/ScenePreviewTests.swift -o build/tests/scene-preview-tests
build/tests/scene-preview-tests
