#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p dist
codesign --verify --deep --strict build/Flua.app
ditto -c -k --sequesterRsrc --keepParent build/Flua.app dist/Flua.zip
print "Release: $PWD/dist/Flua.zip"
