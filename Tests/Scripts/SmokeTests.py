#!/usr/bin/env python3
import os
from pathlib import Path
import subprocess
import tempfile

source = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix='flua-smoke-tests-') as temporary:
    root = Path(temporary).resolve()
    (root / 'scripts').mkdir()
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
    normal = root / 'build/Flua.app'
    normal.mkdir(parents=True)
    (normal / 'sentinel').write_text('unchanged')
    environment = dict(os.environ, PATH=f'{fake_bin}:{os.environ["PATH"]}')
    for detached in (False, True):
        if detached:
            subprocess.run(['git', 'checkout', '--detach'], cwd=root, check=True, capture_output=True)
        subprocess.run(['make', '-f', str(source / 'Makefile'), 'smoke'],
                       cwd=root, env=environment, check=True)
        suffix = subprocess.check_output(['git', 'rev-parse', '--short', 'HEAD'], cwd=root, text=True).strip() if detached else 'test-nested'
        assert Path((root / 'builds.txt').read_text().splitlines()[-1]).name == f'Flua-{suffix}.app'
    catalogs = (root / 'catalogs.txt').read_text().splitlines()
    assert len(set(catalogs)) == 2
    assert all(Path(catalog).is_relative_to(root / 'build/verification') for catalog in catalogs)
    assert (normal / 'sentinel').read_text() == 'unchanged'
print('PASS: smoke build naming, isolated catalogs and regular bundle preservation')
