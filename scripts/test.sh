#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
python3 Tests/Scripts/SmokeTests.py
python3 Tests/Scripts/SystemTestLockTests.py
python3 Tests/Scripts/ReleaseTests.py
mkdir -p build/tests/SceneAssets
cp -R Sources/Flua/SceneAssets/. build/tests/SceneAssets/
swiftc Sources/Flua/Model.swift Sources/Flua/LibraryPaths.swift Tests/FluaTests/ModelTests.swift -o build/tests/model-tests
build/tests/model-tests
swiftc -target arm64-apple-macosx27.0 \
    Sources/Flua/Model.swift \
    Sources/Flua/OnlineCatalog.swift \
    Sources/Flua/OnlineRangePreview.swift \
    Tests/FluaTests/OnlineDownloadTests.swift \
    -o build/tests/online-download-tests
build/tests/online-download-tests
swiftc -parse-as-library -target arm64-apple-macosx27.0 \
    Sources/Flua/Model.swift \
    Sources/Flua/OnlineCatalog.swift \
    Sources/Flua/OnlineCatalogBrowser.swift \
    Sources/Flua/OnlineCatalogProviders.swift \
    Sources/Flua/OnlineCatalogPublicProviders.swift \
    Sources/Flua/OnlineCatalogStockProviders.swift \
    Tests/FluaTests/OnlineCatalogBrowsingTests.swift \
    -o build/tests/online-catalog-browsing-tests
build/tests/online-catalog-browsing-tests
swiftc -parse-as-library -target arm64-apple-macosx27.0 \
    Sources/Flua/Model.swift \
    Sources/Flua/OnlineCatalog.swift \
    Sources/Flua/OnlineCatalogBrowser.swift \
    Sources/Flua/OnlineCatalogProviders.swift \
    Sources/Flua/OnlineCatalogPublicProviders.swift \
    Sources/Flua/OnlineCatalogStockProviders.swift \
    Tests/FluaTests/OnlineCatalogProviderTestFixture.swift \
    Tests/FluaTests/OnlineCatalogPublicProviderTests.swift \
    -o build/tests/online-catalog-public-provider-tests
build/tests/online-catalog-public-provider-tests
swiftc -parse-as-library -target arm64-apple-macosx27.0 \
    Sources/Flua/Model.swift \
    Sources/Flua/OnlineCatalog.swift \
    Sources/Flua/OnlineCatalogBrowser.swift \
    Sources/Flua/OnlineCatalogProviders.swift \
    Sources/Flua/OnlineCatalogPublicProviders.swift \
    Sources/Flua/OnlineCatalogStockProviders.swift \
    Tests/FluaTests/OnlineCatalogStockProviderTests.swift \
    -o build/tests/online-catalog-stock-provider-tests
build/tests/online-catalog-stock-provider-tests
swiftc -O \
    Sources/Flua/Model.swift \
    Sources/Flua/LibraryPaths.swift \
    Tests/FluaTests/CatalogPublicationTests.swift \
    -o build/tests/catalog-publication-tests
build/tests/catalog-publication-tests
swiftc Sources/Flua/LibraryWindowLaunchPolicy.swift Tests/FluaTests/LibraryWindowLaunchPolicyTests.swift -o build/tests/library-window-launch-policy-tests
build/tests/library-window-launch-policy-tests
swiftc -target arm64-apple-macosx27.0 Sources/Flua/ImageThumbnail.swift Tests/FluaTests/ImageThumbnailTests.swift -o build/tests/image-thumbnail-tests
build/tests/image-thumbnail-tests
swiftc -parse-as-library -target arm64-apple-macosx27.0 Sources/Flua/Model.swift Sources/Flua/LibraryPaths.swift Sources/Flua/Engine.swift Sources/Flua/NativeWallpaperStore.swift Sources/Flua/NativeWallpaper.swift Sources/Flua/ImageThumbnail.swift Sources/Flua/MediaFacts.swift Sources/Flua/SceneView.swift Sources/Flua/ScenePreviewRenderer.swift Sources/Flua/SceneDrawing.swift Sources/Flua/ScenePackage.swift Sources/Flua/Library.swift Tests/FluaTests/ClearFiltersSortTests.swift -o build/tests/clear-filters-sort-tests
build/tests/clear-filters-sort-tests
swiftc -target arm64-apple-macosx27.0 Sources/Flua/ScenePackage.swift Tests/FluaTests/ScenePackageTests.swift -o build/tests/package-tests
build/tests/package-tests
swiftc -target arm64-apple-macosx27.0 Sources/Flua/ImageExport.swift Tests/FluaTests/ImageExportTests.swift -o build/tests/image-export-tests
build/tests/image-export-tests
swiftc -target arm64-apple-macosx27.0 Sources/Flua/Model.swift Sources/Flua/NativeWallpaperStore.swift Sources/Flua/NativeWallpaper.swift Tests/FluaTests/NativeWallpaperTests.swift -o build/tests/native-wallpaper-tests
build/tests/native-wallpaper-tests
swiftc -target arm64-apple-macosx27.0 Sources/Flua/AccentColor.swift Tests/FluaTests/AccentColorTests.swift -o build/tests/accent-color-tests
build/tests/accent-color-tests
swiftc -parse-as-library -target arm64-apple-macosx27.0 Sources/Flua/Focus.swift "$PWD/Tests/FluaTests/FocusTests.swift" -o build/tests/focus-tests
build/tests/focus-tests
swiftc -parse-as-library -target arm64-apple-macosx27.0 Tests/FluaTests/InstallerTests.swift -o build/tests/installer-tests
build/tests/installer-tests
swiftc -O -target arm64-apple-macosx27.0 Sources/Flua/SceneDrawing.swift Tests/FluaTests/ScenePreviewTests.swift -o build/tests/scene-preview-tests
build/tests/scene-preview-tests
