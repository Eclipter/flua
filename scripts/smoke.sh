#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
require_no_flua() {
    if /usr/bin/pgrep -x Flua; then
        print -u2 "Quit the running Flua before verification. Smoke tests never launch alongside another instance."
        exit 1
    fi
}
require_no_flua
mkdir -p build/verification
run_dir=$(mktemp -d "$PWD/build/verification/run.XXXXXX")
# Offscreen accessibility names. Launching the binary directly does not activate the app.
"$PWD/build/Flua.app/Contents/MacOS/Flua" \
    --data-dir "$run_dir/accessibility-library" \
    --accessibility-audit "$run_dir/results/accessibility.json"
require_no_flua
open -g -W "$PWD/build/Flua.app" \
    --args \
    --data-dir "$run_dir/library" \
    --smoke-test "$run_dir/results"
python3 - "$run_dir/results/smoke-results.json" <<'PYTHON'
import json, sys
with open(sys.argv[1]) as f: result = json.load(f)
assert result.get('passed') is True and not result.get('failures'), result
print('PASS: application smoke tests; results:', sys.argv[1])
PYTHON
