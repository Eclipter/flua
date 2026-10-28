#!/bin/sh
set -eu
FS_SOURCE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
FS_BUILD_DIR=${1:-"$FS_SOURCE_DIR/Built"}
FS_TARGET="$(uname -m)-apple-macosx26.0"
FS_BUNDLE="$FS_BUILD_DIR/FluaWallpaperExtension.appex"
mkdir -p "$FS_BUILD_DIR" "$FS_BUNDLE/Contents/MacOS" "$FS_BUNDLE/Contents/Resources"
mkdir -p "$FS_BUILD_DIR/SceneAssets" "$FS_BUNDLE/Contents/Resources/SceneAssets"
cp "$FS_SOURCE_DIR/Info.plist" "$FS_BUNDLE/Contents/Info.plist"
cp -R "$FS_SOURCE_DIR/../Flua/SceneAssets/." "$FS_BUILD_DIR/SceneAssets/"
cp -R "$FS_SOURCE_DIR/../Flua/SceneAssets/." "$FS_BUNDLE/Contents/Resources/SceneAssets/"
cp "$FS_SOURCE_DIR/PrototypeThumbnail.png" "$FS_BUNDLE/Contents/Resources/PrototypeThumbnail.png"
cp "$FS_SOURCE_DIR/PrototypeThumbnail.png" "$FS_BUILD_DIR/PrototypeThumbnail.png"
xcrun clang -target "$FS_TARGET" -fobjc-arc -framework Foundation -framework CoreMedia -framework CoreGraphics -framework AVFoundation -framework CoreImage -framework ImageIO -framework UniformTypeIdentifiers -framework CoreVideo "$FS_SOURCE_DIR/generate-fixtures.m" -o "$FS_BUILD_DIR/generate-fixtures"
"$FS_BUILD_DIR/generate-fixtures" "$FS_BUILD_DIR"
cp "$FS_BUILD_DIR/FluaMotion.mov" "$FS_BUILD_DIR/FluaStill.png" "$FS_BUNDLE/Contents/Resources/"
xcrun clang -target "$FS_TARGET" -fobjc-arc -Wno-deprecated-declarations -c "$FS_SOURCE_DIR/MediaRenderer.m" -o "$FS_BUILD_DIR/MediaRenderer.o"
xcrun clang -target "$FS_TARGET" -fobjc-arc -Wall -Wextra -c "$FS_SOURCE_DIR/PlaybackPolicy.m" -o "$FS_BUILD_DIR/PlaybackPolicy.o"
xcrun clang -target "$FS_TARGET" -fobjc-arc -Wall -Wextra -Wno-unused-parameter -c "$FS_SOURCE_DIR/Provider.m" -o "$FS_BUILD_DIR/Provider.o"
# ExtensionFoundation bootstraps the host environment before invoking Swift main.
xcrun swiftc -target "$FS_TARGET" -O -parse-as-library -Xlinker -e -Xlinker _NSExtensionMain -import-objc-header "$FS_SOURCE_DIR/Provider.h" "$FS_SOURCE_DIR/EntryPoint.swift" "$FS_SOURCE_DIR/SceneBridge.swift" "$FS_SOURCE_DIR/../Flua/SceneDrawing.swift" "$FS_BUILD_DIR/Provider.o" "$FS_BUILD_DIR/MediaRenderer.o" "$FS_BUILD_DIR/PlaybackPolicy.o" -framework IOKit -framework ColorSync -framework Foundation -framework QuartzCore -framework IOSurface -framework CoreGraphics -framework CoreMedia -framework AVFoundation -framework CoreImage -framework CoreVideo -framework ImageIO -o "$FS_BUNDLE/Contents/MacOS/FluaWallpaperExtension"
sh "$FS_SOURCE_DIR/verify-entrypoint.sh" "$FS_BUNDLE/Contents/MacOS/FluaWallpaperExtension"
codesign --force --sign - "$FS_BUNDLE"
codesign --verify --strict "$FS_BUNDLE"
plutil -lint "$FS_BUNDLE/Contents/Info.plist"
if [ "${2:-}" = --build-only ]; then exit 0; fi
xcrun clang -target "$FS_TARGET" -fobjc-arc \
    -framework Foundation -framework QuartzCore -framework IOSurface \
    -framework CoreGraphics -framework CoreMedia -framework AVFoundation \
    -framework CoreImage -framework CoreVideo -framework ImageIO \
    "$FS_SOURCE_DIR/image-decoder-test.m" "$FS_BUILD_DIR/MediaRenderer.o" \
    -o "$FS_BUILD_DIR/image-decoder-test"
"$FS_BUILD_DIR/image-decoder-test"
xcrun clang -target "$FS_TARGET" -fobjc-arc -DFS_SELF_TEST -framework Foundation -framework QuartzCore -framework IOSurface -framework CoreGraphics -framework CoreMedia -framework AVFoundation -framework CoreImage -framework CoreVideo -framework ImageIO "$FS_SOURCE_DIR/Provider.m" "$FS_BUILD_DIR/MediaRenderer.o" "$FS_BUILD_DIR/PlaybackPolicy.o" -framework IOKit -framework ColorSync -o "$FS_BUILD_DIR/provider-self-test"
"$FS_BUILD_DIR/provider-self-test" > "$FS_BUILD_DIR/provider-self-test.json"
xcrun clang -target "$FS_TARGET" -fobjc-arc -DFS_WIRE_PROOF -framework Foundation -framework QuartzCore -framework IOSurface -framework CoreGraphics -framework CoreMedia -framework AVFoundation -framework CoreImage -framework CoreVideo -framework ImageIO "$FS_SOURCE_DIR/Provider.m" "$FS_BUILD_DIR/MediaRenderer.o" "$FS_BUILD_DIR/PlaybackPolicy.o" -framework IOKit -framework ColorSync "$FS_SOURCE_DIR/wire-proof.m" -o "$FS_BUILD_DIR/wire-proof"
"$FS_BUILD_DIR/wire-proof" > "$FS_BUILD_DIR/wire-proof.json"
cat "$FS_BUILD_DIR/provider-self-test.json" "$FS_BUILD_DIR/wire-proof.json"

xcrun clang -target "$FS_TARGET" -fobjc-arc -DFS_MEDIA_TEST -c "$FS_SOURCE_DIR/Provider.m" -o "$FS_BUILD_DIR/media-provider.o"
xcrun swiftc -target "$FS_TARGET" -O -import-objc-header "$FS_SOURCE_DIR/Provider.h" "$FS_SOURCE_DIR/SceneBridge.swift" "$FS_SOURCE_DIR/../Flua/SceneDrawing.swift" "$FS_BUILD_DIR/media-provider.o" "$FS_BUILD_DIR/MediaRenderer.o" "$FS_BUILD_DIR/PlaybackPolicy.o" -framework IOKit -framework ColorSync -framework Foundation -framework QuartzCore -framework IOSurface -framework CoreGraphics -framework CoreMedia -framework AVFoundation -framework CoreImage -framework CoreVideo -framework ImageIO -o "$FS_BUILD_DIR/media-self-test"
"$FS_BUILD_DIR/media-self-test" "$FS_BUILD_DIR" > "$FS_BUILD_DIR/media-self-test.json"
cat "$FS_BUILD_DIR/media-self-test.json"
