#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p dist
codesign --verify --strict build/Flua.app
ditto -c -k --sequesterRsrc --keepParent build/Flua.app dist/Flua-macOS.zip
print "Release: $PWD/dist/Flua-macOS.zip"
