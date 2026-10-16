#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
swift build -c release --triple arm64-apple-macosx15.0
bin_dir=$(swift build -c release --triple arm64-apple-macosx15.0 --show-bin-path)
app="$PWD/build/Flua.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_dir/Flua" "$app/Contents/MacOS/Flua"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/AppIcon.icns "$app/Contents/Resources/"
codesign --force --sign - "$app"
codesign --verify --strict "$app"
# Let Launch Services notice changes to files inside an existing bundle.
touch "$app"
print "Built: $app"
