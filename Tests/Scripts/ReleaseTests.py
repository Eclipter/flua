#!/usr/bin/env python3
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import zipfile

source = Path(__file__).resolve().parents[2]
version_paths = ('Resources/Info.plist', 'Sources/WallpaperExtension/Info.plist')
for failure in ('', 'build', 'codesign', 'ditto', 'mismatch', 'invalid'):
    with tempfile.TemporaryDirectory(prefix='flua-release-tests-') as temporary:
        root = Path(temporary)
        (root / 'scripts').mkdir()
        shutil.copy2(source / 'Makefile', root / 'Makefile')
        shutil.copy2(source / 'scripts/release.sh', root / 'scripts/release.sh')
        for relative in version_paths:
            path = root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source / relative, path)
        if failure in ('mismatch', 'invalid'):
            path = root / version_paths[1]
            metadata = plistlib.loads(path.read_bytes())
            metadata['CFBundleShortVersionString'] = '0.2.0' if failure == 'mismatch' else 'preview'
            path.write_bytes(plistlib.dumps(metadata))
            if failure == 'invalid':
                path = root / version_paths[0]
                metadata = plistlib.loads(path.read_bytes())
                metadata['CFBundleShortVersionString'] = 'preview'
                path.write_bytes(plistlib.dumps(metadata))
        originals = {relative: (root / relative).read_bytes() for relative in version_paths}
        original_info = plistlib.loads(originals[version_paths[0]])
        (root / 'scripts/build.sh').write_text('''#!/usr/bin/env python3
import os
from pathlib import Path
import shutil

assert all(key not in os.environ for key in (
    'FLUA_APP_PATH', 'FLUA_CATALOG_PATH', 'FLUA_WALLPAPER_IDENTIFIER'))
Path('build-called').touch()
if os.environ['FLUA_RELEASE_TEST_FAIL'] == 'build':
    raise SystemExit(1)
for source, target in (
    ('Resources/Info.plist', 'build/Flua.app/Contents/Info.plist'),
    ('Sources/WallpaperExtension/Info.plist',
     'build/Flua.app/Contents/Extensions/FluaWallpaperExtension.appex/Contents/Info.plist'),
):
    Path(target).parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, target)
''')
        (root / 'scripts/build.sh').chmod(0o755)
        fake_bin = root / 'bin'
        fake_bin.mkdir()
        for tool in ('codesign', 'ditto'):
            executable = fake_bin / tool
            executable.write_text('''#!/usr/bin/env python3
import os
from pathlib import Path
import sys
import zipfile

stage = Path(sys.argv[0]).name
if os.environ['FLUA_RELEASE_TEST_FAIL'] == stage:
    if stage == 'ditto':
        Path(sys.argv[-1]).write_bytes(b'incomplete archive')
    raise SystemExit(1)
if stage == 'ditto':
    app = Path(sys.argv[-2])
    with zipfile.ZipFile(sys.argv[-1], 'w') as archive:
        for path in app.rglob('*'):
            if path.is_file():
                archive.write(path, path.relative_to(app.parent))
''')
            executable.chmod(0o755)
        archive = root / 'dist/Flua.zip'
        archive.parent.mkdir()
        archive.write_bytes(b'previous archive')
        environment = dict(os.environ, PATH=f'{fake_bin}:{os.environ["PATH"]}',
                           FLUA_APP_PATH='/invalid/test-app', FLUA_CATALOG_PATH='/invalid/test-catalog',
                           FLUA_WALLPAPER_IDENTIFIER='invalid.test.provider', FLUA_RELEASE_TEST_FAIL=failure)
        if not failure:
            build_environment = {key: value for key, value in environment.items() if key not in (
                'FLUA_APP_PATH', 'FLUA_CATALOG_PATH', 'FLUA_WALLPAPER_IDENTIFIER')}
            subprocess.run(['make', 'build'], cwd=root, env=build_environment, check=True)
            assert all((root / relative).read_bytes() == data for relative, data in originals.items())
            assert archive.read_bytes() == b'previous archive'
            print('PASS: ordinary builds preserve versions and the release archive')
        for release in range(1, 3) if not failure else (1,):
            result = subprocess.run(['make', 'release'], cwd=root, env=environment,
                                    capture_output=True, text=True)
            assert (result.returncode == 0) == (not failure), result.stdout + result.stderr
            assert not list(archive.parent.glob('.release.*'))
            if failure:
                assert archive.read_bytes() == b'previous archive'
                assert all((root / relative).read_bytes() == data for relative, data in originals.items())
                assert (root / 'build-called').exists() == (failure not in ('mismatch', 'invalid'))
            else:
                major, minor, patch = map(int, original_info['CFBundleShortVersionString'].split('.'))
                expected = (f'{major}.{minor}.{patch + release}', str(int(original_info['CFBundleVersion']) + release))
                for relative in version_paths:
                    info = plistlib.loads((root / relative).read_bytes())
                    assert (info['CFBundleShortVersionString'], info['CFBundleVersion']) == expected
                with zipfile.ZipFile(archive) as packaged:
                    assert len(packaged.namelist()) == 2
                    for name in packaged.namelist():
                        info = plistlib.loads(packaged.read(name))
                        assert (info['CFBundleShortVersionString'], info['CFBundleVersion']) == expected
        print(f'PASS: release {failure or "bumps before building and packaging, including repeated releases"}')
