#!/usr/bin/env python3
import os
from pathlib import Path
import subprocess
import tempfile

source = Path(__file__).resolve().parents[2]
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
print '#!/bin/zsh' > "$FLUA_APP_PATH/Contents/MacOS/Flua"
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
mkdir -p "$8"
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
