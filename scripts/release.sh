#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p .build
touch .build/flua-release.lock
zmodload zsh/system
zsystem flock -t 0 .build/flua-release.lock || { print -u2 'A Flua release is already running.'; exit 1; }

backup=$(mktemp -d)
cp Resources/Info.plist "$backup/app.plist"
cp Sources/WallpaperExtension/Info.plist "$backup/extension.plist"
archive_dir=''
publishing=0
released=0
cleanup() {
    local result=$?
    if (( ! released )); then
        cp "$backup/app.plist" Resources/Info.plist
        cp "$backup/extension.plist" Sources/WallpaperExtension/Info.plist
        if (( publishing )); then
            for asset in Flua.zip appcast.xml; do
                if [[ -f "$archive_dir/previous/$asset" ]]; then
                    mv -f "$archive_dir/previous/$asset" "dist/$asset"
                else
                    rm -f "dist/$asset"
                fi
            done
        fi
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
    FLUA_ENABLE_UPDATES=1 \
    make build
mkdir -p dist
archive_dir=$(mktemp -d "$PWD/dist/.release.XXXXXX")
codesign --verify --deep --strict build/Flua.app
ditto -c -k --sequesterRsrc --keepParent build/Flua.app "$archive_dir/Flua.zip"
sparkle=$(./scripts/sparkle.sh)
public_key=$("$sparkle/bin/generate_keys" --account local.flua.desktop -p)
python3 - "$public_key" <<'PY'
import plistlib
import sys
from pathlib import Path

expected = ''.join(sys.argv[1].split())
metadata = plistlib.loads(Path('build/Flua.app/Contents/Info.plist').read_bytes())
actual = metadata.get('SUPublicEDKey', '')
if (not expected or actual != expected
        or metadata.get('SURequireSignedFeed') is not True
        or metadata.get('SUVerifyUpdateBeforeExtraction') is not True
        or metadata.get('SUFeedURL') != 'https://github.com/Eclipter/flua/releases/latest/download/appcast.xml'):
    raise SystemExit('Flua.app has an invalid Sparkle signing key or signed-feed configuration.')
PY
download_prefix="https://github.com/Eclipter/flua/releases/download/v$version/"
"$sparkle/bin/generate_appcast" \
    --account local.flua.desktop \
    --download-url-prefix "$download_prefix" \
    --maximum-deltas 0 \
    -o "$archive_dir/appcast.xml" \
    "$archive_dir"
"$sparkle/bin/sign_update" --account local.flua.desktop --verify "$archive_dir/appcast.xml"
signature=$(python3 - "$archive_dir" "${download_prefix}Flua.zip" <<'PY'
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

directory = Path(sys.argv[1])
feed = ET.parse(directory / 'appcast.xml')
enclosure = feed.find('./channel/item/enclosure')
signature = enclosure.get('{http://www.andymatuschak.org/xml-namespaces/sparkle}edSignature') if enclosure is not None else None
if (not signature or enclosure.get('url') != sys.argv[2]
        or enclosure.get('length') != str((directory / 'Flua.zip').stat().st_size)):
    raise SystemExit('Sparkle did not generate a valid Flua.zip enclosure.')
print(signature)
PY
)
"$sparkle/bin/sign_update" --account local.flua.desktop --verify "$archive_dir/Flua.zip" "$signature"

mkdir "$archive_dir/previous"
for asset in Flua.zip appcast.xml; do
    if [[ -L "dist/$asset" || ( -e "dist/$asset" && ! -f "dist/$asset" ) ]]; then
        print -u2 "Release destination dist/$asset must be a regular file."
        exit 1
    fi
    if [[ -f "dist/$asset" ]]; then
        cp -p "dist/$asset" "$archive_dir/previous/$asset"
    fi
done
publishing=1
mv -f "$archive_dir/Flua.zip" dist/Flua.zip
mv -f "$archive_dir/appcast.xml" dist/appcast.xml
released=1
print "Release $version: $PWD/dist/Flua.zip and $PWD/dist/appcast.xml"
