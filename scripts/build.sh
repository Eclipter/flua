#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
swift build -c release --triple arm64-apple-macosx15.0
bin_dir=$(swift build -c release --triple arm64-apple-macosx15.0 --show-bin-path)
app="$PWD/build/Flua.app"
extension_build="$PWD/build/wallpaper"
extension="$app/Contents/Extensions/FluaWallpaperExtension.appex"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Extensions" "$app/Contents/Helpers"
cp "$bin_dir/Flua" "$app/Contents/MacOS/Flua"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/AppIcon.icns "$app/Contents/Resources/"
cp -R "$bin_dir/Flua_Flua.bundle" "$app/Contents/Resources/"
sh Sources/WallpaperExtension/build-and-test.sh "$extension_build" --build-only
xcrun clang -target arm64-apple-macosx15.0 -Wall -Wextra -Werror \
    Sources/WallpaperExtension/AgentGuard.c -o "$app/Contents/Helpers/FluaWallpaperGuard"
codesign --force --sign - "$app/Contents/Helpers/FluaWallpaperGuard"
ditto "$extension_build/FluaWallpaperExtension.appex" "$extension"
python3 - "$extension/Contents/Info.plist" "$extension_build/entitlements.plist" <<'PY'
import os
import plistlib
import sys
from pathlib import Path

info_path, entitlements_path = map(Path, sys.argv[1:])
with info_path.open('rb') as source:
    info = plistlib.load(source)
info.update(CFBundleIdentifier=os.environ.get('FLUA_WALLPAPER_IDENTIFIER', 'local.flua.desktop.wallpaper'),
            CFBundleName='Flua Wallpaper', CFBundleDisplayName='Flua',
            FLUALibraryOnly=True)
entitlements = {'com.apple.security.app-sandbox': True}
catalog = os.environ.get('FLUA_CATALOG_PATH')
if catalog:
    catalog = str(Path(catalog).resolve())
    info['FLUACatalogPath'] = catalog
    entitlements['com.apple.security.temporary-exception.files.absolute-path.read-only'] = [catalog]
else:
    # Apple's home-relative sandbox exceptions also require an initial slash.
    entitlements['com.apple.security.temporary-exception.files.home-relative-path.read-only'] = [
        '/Library/Application Support/Flua/catalog.json']
for key, paths in entitlements.items():
    if key.startswith('com.apple.security.temporary-exception.files.'):
        assert all(path.startswith('/') and not path.endswith('/') for path in paths)
with info_path.open('wb') as target:
    plistlib.dump(info, target)
with entitlements_path.open('wb') as target:
    plistlib.dump(entitlements, target)
PY
codesign --force --sign - --entitlements "$extension_build/entitlements.plist" "$extension"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
# Let Launch Services notice changes to files inside an existing bundle.
touch "$app"
print "Built: $app"
