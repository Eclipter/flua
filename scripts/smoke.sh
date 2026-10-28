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
# Keep test data and the launch working directory outside privacy-protected folders.
run_dir=$(mktemp -d /private/tmp/flua-smoke.XXXXXX)
ln -s "$run_dir" "$PWD/build/verification/${run_dir:t}"
print "Smoke workspace: $run_dir"
app="$PWD/build/Flua.app"
FLUA_APP_PATH="$app" \
    FLUA_CATALOG_PATH="$run_dir/library/catalog.json" \
    ./scripts/build.sh
cd "$run_dir"
mkdir -p "$run_dir/results"
bound_library="$run_dir/library"
mkdir -p "$bound_library"
print -rn -- "Disposable catalog must remain unopened." > "$bound_library/verification-sentinel"
if "$app/Contents/MacOS/Flua" \
    --accessibility-audit "$run_dir/results/missing-data-audit.json" \
    2>"$run_dir/results/missing-data-audit.stderr"; then
    print -u2 "Accessibility audit unexpectedly launched without --data-dir."
    exit 1
fi
if ! /usr/bin/grep -q "requires an isolated --data-dir" "$run_dir/results/missing-data-audit.stderr"; then
    print -u2 "Accessibility audit failed without the expected isolated --data-dir error."
    exit 1
fi
if [[ "$(cat "$bound_library/verification-sentinel")" != "Disposable catalog must remain unopened." \
    || -e "$bound_library/Media" || -e "$bound_library/library.json" || -e "$bound_library/catalog.json" ]]; then
    print -u2 "Accessibility audit accessed the bound catalog without --data-dir."
    exit 1
fi
rm "$bound_library/verification-sentinel"
rmdir "$bound_library"
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
state['hideFromDock'] = False
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
    assert result['passed'] is True and result['windowVisible'] is shown, result
    assert result['showWindowOnStartup'] is shown and result['hidesDockIcon'] is False, result
    assert result['fullScreenEligible'] is shown, result
    assert result['windowControlsVisible'] is shown, result
    assert result['activationPolicy'] == 0, result
    if shown:
        frame, visible_frame = result['windowFrame'], result['screenVisibleFrame']
        assert len(frame) == len(visible_frame) == 4, result
        assert all(abs(actual - expected) <= 1 for actual, expected in zip(frame, visible_frame)), result
        assert result['isNativeFullScreen'] is False, result
print('PASS: normal startup honors both startup window settings')
PYTHON
accessory_dir="$run_dir/startup-hide-from-dock"
mkdir -p "$accessory_dir"
python3 - "$run_dir/startup-true/library.json" "$accessory_dir/library.json" <<'PYTHON'
import json
from pathlib import Path
import sys
state = json.loads(Path(sys.argv[1]).read_text())
state['hideFromDock'] = True
Path(sys.argv[2]).write_text(json.dumps(state))
PYTHON
require_no_flua
"$app/Contents/MacOS/Flua" \
    --data-dir "$accessory_dir" \
    --startup-smoke "$run_dir/results/startup-hide-from-dock.json"
python3 - "$run_dir/results/startup-hide-from-dock.json" <<'PYTHON'
import json, sys
result = json.load(open(sys.argv[1]))
assert result['passed'] is True and result['windowVisible'] is True, result
assert result['hidesDockIcon'] is True and result['activationPolicy'] == 1, result
assert result['fullScreenEligible'] is True and result['windowControlsVisible'] is True, result
frame, visible_frame = result['windowFrame'], result['screenVisibleFrame']
assert len(frame) == len(visible_frame) == 4, result
assert all(abs(actual - expected) <= 1 for actual, expected in zip(frame, visible_frame)), result
assert result['isNativeFullScreen'] is False, result
print('PASS: Hide from Dock preserves fullscreen eligibility')
PYTHON
