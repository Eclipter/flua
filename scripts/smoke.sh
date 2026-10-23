#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
if ! ./scripts/system-test-lock.py --is-locked; then
    exec ./scripts/system-test-lock.py "smoke" "$PWD/scripts/smoke.sh" "$@"
fi
require_no_flua() {
    if /usr/bin/pgrep -x Flua; then
        print -u2 "Quit the running Flua before verification. Smoke tests never launch alongside another instance."
        exit 1
    fi
}
require_no_flua
mkdir -p build/verification
run_dir=$(mktemp -d "$PWD/build/verification/run.XXXXXX")
app="$PWD/build/Flua.app"
FLUA_APP_PATH="$app" \
    FLUA_CATALOG_PATH="$run_dir/library/catalog.json" \
    ./scripts/build.sh
# Offscreen accessibility names. Launching the binary directly does not activate the app.
"$app/Contents/MacOS/Flua" \
    --data-dir "$run_dir/accessibility-library" \
    --accessibility-audit "$run_dir/results/accessibility.json"
require_no_flua
open -g -W "$app" \
    --args \
    --data-dir "$run_dir/library" \
    --smoke-test "$run_dir/results"
python3 - "$run_dir/results/smoke-results.json" <<'PYTHON'
import json, sys
with open(sys.argv[1]) as f: result = json.load(f)
assert result.get('passed') is True and not result.get('failures'), result
print('PASS: application smoke tests; results:', sys.argv[1])
PYTHON

for shown in false true; do
    require_no_flua
    startup_dir="$run_dir/startup-$shown"
    mkdir -p "$startup_dir"
    python3 - "$run_dir/library/library.json" "$startup_dir/library.json" "$shown" <<'PYTHON'
import json
from pathlib import Path
import sys
state = json.loads(Path(sys.argv[1]).read_text())
state['showWindowOnStartup'] = sys.argv[3] == 'true'
state['nativePlayback'] = {}
Path(sys.argv[2]).write_text(json.dumps(state))
PYTHON
    "$app/Contents/MacOS/Flua" \
        --data-dir "$startup_dir" \
        --startup-smoke "$run_dir/results/startup-$shown.json"
done
python3 - "$run_dir/results" <<'PYTHON'
import json
from pathlib import Path
import sys
for shown in (False, True):
    result = json.loads((Path(sys.argv[1]) / f'startup-{str(shown).lower()}.json').read_text())
    assert result == {'passed': True, 'windowVisible': shown, 'showWindowOnStartup': shown}, result
print('PASS: normal startup honors both startup window settings')
PYTHON
