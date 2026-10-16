#!/bin/sh
set -eu
FS_SOURCE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
FS_BUILD_DIR=${1:-"$FS_SOURCE_DIR/Built"}
FS_TARGET="$(uname -m)-apple-macosx26.0"
FS_BUNDLE="$FS_BUILD_DIR/FluaWallpaperExtension.appex"
mkdir -p "$FS_BUILD_DIR" "$FS_BUNDLE/Contents/MacOS" "$FS_BUNDLE/Contents/Resources"
cp "$FS_SOURCE_DIR/Info.plist" "$FS_BUNDLE/Contents/Info.plist"
cp "$FS_SOURCE_DIR/PrototypeThumbnail.png" "$FS_BUNDLE/Contents/Resources/PrototypeThumbnail.png"
cp "$FS_SOURCE_DIR/PrototypeThumbnail.png" "$FS_BUILD_DIR/PrototypeThumbnail.png"
xcrun clang -target "$FS_TARGET" -fobjc-arc -framework Foundation -framework CoreMedia -framework CoreGraphics -framework AVFoundation -framework CoreImage -framework ImageIO -framework UniformTypeIdentifiers -framework CoreVideo "$FS_SOURCE_DIR/generate-fixtures.m" -o "$FS_BUILD_DIR/generate-fixtures"
"$FS_BUILD_DIR/generate-fixtures" "$FS_BUILD_DIR"
cp "$FS_BUILD_DIR/FluaMotion.mov" "$FS_BUILD_DIR/FluaStill.png" "$FS_BUNDLE/Contents/Resources/"
xcrun clang -target "$FS_TARGET" -fobjc-arc -Wno-deprecated-declarations -c "$FS_SOURCE_DIR/MediaRenderer.m" -o "$FS_BUILD_DIR/MediaRenderer.o"
xcrun clang -target "$FS_TARGET" -fobjc-arc -Wall -Wextra -Wno-unused-parameter -c "$FS_SOURCE_DIR/Provider.m" -o "$FS_BUILD_DIR/Provider.o"
xcrun swiftc -target "$FS_TARGET" -parse-as-library -import-objc-header "$FS_SOURCE_DIR/Provider.h" "$FS_SOURCE_DIR/EntryPoint.swift" "$FS_BUILD_DIR/Provider.o" "$FS_BUILD_DIR/MediaRenderer.o" -framework Foundation -framework QuartzCore -framework IOSurface -framework CoreGraphics -framework CoreMedia -framework CoreGraphics -framework AVFoundation -framework CoreImage -framework CoreVideo -framework ImageIO -o "$FS_BUNDLE/Contents/MacOS/FluaWallpaperExtension"
codesign --force --sign - "$FS_BUNDLE"
codesign --verify --strict "$FS_BUNDLE"
plutil -lint "$FS_BUNDLE/Contents/Info.plist"
xcrun clang -target "$FS_TARGET" -fobjc-arc -DFS_SELF_TEST -framework Foundation -framework QuartzCore -framework IOSurface -framework CoreGraphics -framework CoreMedia -framework CoreGraphics -framework AVFoundation -framework CoreImage -framework CoreVideo -framework ImageIO "$FS_SOURCE_DIR/Provider.m" "$FS_BUILD_DIR/MediaRenderer.o" -o "$FS_BUILD_DIR/provider-self-test"
"$FS_BUILD_DIR/provider-self-test" > "$FS_BUILD_DIR/provider-self-test.json"
xcrun clang -target "$FS_TARGET" -fobjc-arc -framework Foundation -framework QuartzCore -framework IOSurface -framework CoreGraphics -framework CoreMedia -framework CoreGraphics -framework AVFoundation -framework CoreImage -framework CoreVideo -framework ImageIO "$FS_SOURCE_DIR/Provider.m" "$FS_BUILD_DIR/MediaRenderer.o" "$FS_SOURCE_DIR/wire-proof.m" -o "$FS_BUILD_DIR/wire-proof"
"$FS_BUILD_DIR/wire-proof" > "$FS_BUILD_DIR/wire-proof.json"
cat "$FS_BUILD_DIR/provider-self-test.json" "$FS_BUILD_DIR/wire-proof.json"

xcrun clang -target "$FS_TARGET" -fobjc-arc -DFS_MEDIA_TEST -framework Foundation -framework QuartzCore -framework IOSurface -framework CoreGraphics -framework CoreMedia -framework AVFoundation -framework CoreImage -framework CoreVideo -framework ImageIO "$FS_SOURCE_DIR/Provider.m" "$FS_BUILD_DIR/MediaRenderer.o" -o "$FS_BUILD_DIR/media-self-test"
"$FS_BUILD_DIR/media-self-test" "$FS_BUILD_DIR" > "$FS_BUILD_DIR/media-self-test.json"
cat "$FS_BUILD_DIR/media-self-test.json"
