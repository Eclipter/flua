#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
backup=$(mktemp -d)
cp Resources/Info.plist "$backup/app.plist"
cp Sources/WallpaperExtension/Info.plist "$backup/extension.plist"
archive_dir=''
released=0
cleanup() {
    local result=$?
    if (( ! released )); then
        cp "$backup/app.plist" Resources/Info.plist
        cp "$backup/extension.plist" Sources/WallpaperExtension/Info.plist
    fi
    rm -rf "$backup"
    if [[ -n "$archive_dir" ]]; then
        rm -rf "$archive_dir"
    fi
    return "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
version=$(python3 - <<'PY'
from pathlib import Path
import plistlib
import re

paths = [Path('Resources/Info.plist'), Path('Sources/WallpaperExtension/Info.plist')]
originals = [path.read_bytes() for path in paths]
metadata = [plistlib.loads(data) for data in originals]
keys = ('CFBundleShortVersionString', 'CFBundleVersion')
current = tuple(metadata[0][key] for key in keys)
if current != tuple(metadata[1][key] for key in keys):
    raise SystemExit('App and wallpaper extension versions must match before release.')
version, build = current
if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', version) or not re.fullmatch(r'[0-9]+', build):
    raise SystemExit('Release requires a numeric major.minor.patch version and build number.')
major, minor, patch = map(int, version.split('.'))
next_version = f'{major}.{minor}.{patch + 1}'
updated = []
for data in originals:
    for key, value in zip(keys, (next_version, str(int(build) + 1))):
        pattern = rb'(<key>' + key.encode() + rb'</key>\s*<string>)[^<]*(</string>)'
        data, count = re.subn(pattern, lambda match: match[1] + value.encode() + match[2], data)
        if count != 1:
            raise SystemExit(f'Release requires exactly one {key} field per bundle.')
    updated.append(data)
for path, data in zip(paths, updated):
    path.write_bytes(data)
print(next_version)
PY
)
env -u FLUA_APP_PATH \
    -u FLUA_CATALOG_PATH \
    -u FLUA_WALLPAPER_IDENTIFIER \
    make build
mkdir -p dist
archive_dir=$(mktemp -d "$PWD/dist/.release.XXXXXX")
codesign --verify --deep --strict build/Flua.app
ditto -c -k --sequesterRsrc --keepParent build/Flua.app "$archive_dir/Flua.zip"
mv -f "$archive_dir/Flua.zip" dist/Flua.zip
released=1
print "Release $version: $PWD/dist/Flua.zip"
