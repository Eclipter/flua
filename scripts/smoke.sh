#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p build/verification
run_dir=$(mktemp -d "$PWD/build/verification/run.XXXXXX")
build/Flua.app/Contents/MacOS/Flua --data-dir "$run_dir/library" --smoke-test "$run_dir/results"
python3 - "$run_dir/results/smoke-results.json" <<'PYTHON'
import json, sys
with open(sys.argv[1]) as f: result = json.load(f)
assert result.get('passed') is True and not result.get('failures'), result
print('PASS: application smoke tests; results:', sys.argv[1])
PYTHON
