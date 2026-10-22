#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
if ! ./scripts/system-test-lock.py --is-locked; then
    exec ./scripts/system-test-lock.py "scroll performance" "$PWD/scripts/scroll-test.sh"
fi
if /usr/bin/pgrep -x Flua; then
    print -u2 "Quit Flua before scroll verification."
    exit 1
fi
mkdir -p build/verification build/tests
run_dir=$(mktemp -d "$PWD/build/verification/scroll.XXXXXX")
./scripts/build.sh
swiftc -O -parse-as-library -target arm64-apple-macosx27.0 \
    Tests/FluaTests/ScrollPerformanceTests.swift \
    -o build/tests/scroll-performance-tests
build/tests/scroll-performance-tests "$PWD/build/Flua.app" "$run_dir"
