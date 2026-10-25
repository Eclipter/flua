#!/usr/bin/env python3
import json
import os
from pathlib import Path
import subprocess
import tempfile

source = Path(__file__).resolve().parents[2]
smoke_runner = (source / 'Sources/Flua/SmokeRunner.swift').read_text()
required_checks = next(line.strip() for line in smoke_runner.splitlines() if line.strip().startswith('let required = ['))
aggregation = next(line.strip() for line in smoke_runner.splitlines() if line.strip().startswith('for key in required +'))
passed_assignment = next(line.strip() for line in smoke_runner.splitlines() if line.strip() == 'results["passed"] = failures.isEmpty')
regression_checks = [
    'libraryWindowChrome',
    'instantInspectorResize',
    'desktopPlaylistPreservesLockScreen',
    'desktopStopPreservesLockScreen',
    'surfaceAssignmentsPersisted',
]
for check in regression_checks:
    assert f'"{check}"' in required_checks
swift_source = f'''import Foundation
func evaluate(_ check: String, _ value: Bool?) -> (Bool, [String]) {{
    var results: [String: Any] = [:]
    var failures: [String] = []
    {required_checks}
    for key in required + ["compactWindow"] {{ results[key] = true }}
    if let value {{ results[check] = value }} else {{ results.removeValue(forKey: check) }}
    {aggregation}
    {passed_assignment}
    return (results["passed"] as? Bool == true, failures)
}}
for check in {json.dumps(regression_checks)} {{
    let falseResult = evaluate(check, false)
    precondition(!falseResult.0 && falseResult.1.contains(check))
    let missingResult = evaluate(check, nil)
    precondition(!missingResult.0 && missingResult.1.contains(check))
    let trueResult = evaluate(check, true)
    precondition(trueResult.0 && !trueResult.1.contains(check))
}}
print("PASS: required UI and surface smoke checks fail when false or missing and pass when true")
'''
with tempfile.TemporaryDirectory(prefix='flua-required-smoke-checks-') as temporary:
    swift_file = Path(temporary) / 'RequiredSmokeChecks.swift'
    executable = Path(temporary) / 'required-smoke-checks'
    swift_file.write_text(swift_source)
    subprocess.run(['swiftc', str(swift_file), '-o', str(executable)], check=True)
    subprocess.run([str(executable)], check=True)

with tempfile.TemporaryDirectory(prefix='flua-smoke-tests-') as temporary:
    root = Path(temporary).resolve()
    (root / 'scripts').mkdir()
    lock_script = root / 'scripts/system-test-lock.py'
    lock_script.write_text((source / 'scripts/system-test-lock.py').read_text())
    lock_script.chmod(0o755)
    # The fixture launches no app and must also run during a normal Flua session.
    (root / 'scripts/smoke.sh').write_text(
        (source / 'scripts/smoke.sh').read_text().replace('/usr/bin/pgrep -x Flua', 'false'))
    (root / 'scripts/smoke.sh').chmod(0o755)
    subprocess.run(['git', 'init', '-b', 'test/nested'], cwd=root, check=True, capture_output=True)
    subprocess.run(['git', '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid',
                    'commit', '--allow-empty', '-m', 'fixture'], cwd=root, check=True, capture_output=True)
    build = root / 'scripts/build.sh'
    build.write_text('''#!/bin/zsh
set -eu
mkdir -p "$FLUA_APP_PATH/Contents/MacOS"
print -r -- "$FLUA_APP_PATH" >> builds.txt
print -r -- "$FLUA_CATALOG_PATH" >> catalogs.txt
cat > "$FLUA_APP_PATH/Contents/MacOS/Flua" <<'PYTHON'
#!/usr/bin/env python3
import json
from pathlib import Path
import sys
if '--startup-smoke' in sys.argv:
    library = Path(sys.argv[sys.argv.index('--data-dir') + 1])
    state = json.loads((library / 'library.json').read_text())
    shown = state['showWindowOnStartup']
    hidden = state.get('hideFromDock', False)
    result = Path(sys.argv[sys.argv.index('--startup-smoke') + 1])
    result.write_text(json.dumps({
        'passed': True, 'windowVisible': shown, 'showWindowOnStartup': shown,
        'hidesDockIcon': hidden, 'activationPolicy': 1 if hidden else 0,
        'fullScreenPrimary': shown, 'fullScreenNone': False,
        'fullScreenEligible': shown, 'windowControlsVisible': shown,
    }))
PYTHON
chmod +x "$FLUA_APP_PATH/Contents/MacOS/Flua"
''')
    build.chmod(0o755)
    fake_bin = root / 'bin'
    fake_bin.mkdir()
    temporary = root / 'tmp'
    temporary.mkdir()
    opener = fake_bin / 'open'
    opener.write_text('''#!/bin/zsh
set -eu
[[ "$1" == -g && "$2" == -W && "$4" == --args ]]
[[ "$5" == --data-dir && "$7" == --smoke-test ]]
[[ "$(cat catalogs.txt | tail -1)" == "$6/catalog.json" ]]
[[ -x "$3/Contents/MacOS/Flua" ]]
mkdir -p "$8" "$6"
print '{"nativePlayback":{}}' > "$6/library.json"
print '{"passed":true,"failures":[]}' > "$8/smoke-results.json"
''')
    opener.chmod(0o755)
    environment = dict(os.environ, PATH=f'{fake_bin}:{os.environ["PATH"]}', TMPDIR=str(temporary),
                       FLUA_SYSTEM_TEST_LOCK_PATH=str(root / 'system-test.lock'))
    for detached in (False, True):
        if detached:
            subprocess.run(['git', 'checkout', '--detach'], cwd=root, check=True, capture_output=True)
        subprocess.run([str(lock_script), 'outer smoke', 'make', '-f', str(source / 'Makefile'), 'smoke'],
                       cwd=root, env=environment, check=True)
        assert Path((root / 'builds.txt').read_text().splitlines()[-1]) == root / 'build/Flua.app'
    direct = subprocess.run(
        [str(root / 'scripts/smoke.sh')], cwd=root,
        env=dict(environment, FLUA_SYSTEM_TEST_LOCK_FD='99999'),
        check=True, capture_output=True, text=True,
    )
    assert 'Acquired Flua system-test lock for smoke.' in direct.stdout
    assert len((root / 'builds.txt').read_text().splitlines()) == 3
    catalogs = (root / 'catalogs.txt').read_text().splitlines()
    assert len(set(catalogs)) == 3
    assert all(Path(catalog).is_relative_to(root / 'build/verification') for catalog in catalogs)
print('PASS: one smoke build per run, stable bundle path and isolated catalogs')
