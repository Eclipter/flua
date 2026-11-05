#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"

version=2.10.1
checksum=1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27
distribution="$PWD/.build/sparkle-$version"
if [[ ! -d "$distribution" ]]; then
    mkdir -p .build
    stage=$(mktemp -d "$PWD/.build/sparkle-download.XXXXXX")
    trap 'rm -rf "$stage"' EXIT
    archive="$stage/Sparkle.tar.xz"
    curl -fsSL \
        "https://github.com/sparkle-project/Sparkle/releases/download/$version/Sparkle-$version.tar.xz" \
        -o "$archive"
    printf '%s  %s\n' "$checksum" "$archive" | shasum -a 256 -c >&2
    tar -xf "$archive" -C "$stage" ./Sparkle.framework ./bin ./LICENSE
    rm "$archive"
    python3 - "$stage" "$distribution" <<'PY'
import errno
import os
import sys

try:
    os.rename(sys.argv[1], sys.argv[2])
except OSError as error:
    if error.errno not in (errno.EEXIST, errno.ENOTEMPTY):
        raise
PY
fi
print -r -- "$distribution"
