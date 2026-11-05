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
failures = ('build', 'codesign', 'ditto', 'keys', 'wrong-key', 'appcast', 'verify', 'publish', 'mismatch', 'invalid')

for failure in ('success', *failures):
    with tempfile.TemporaryDirectory(prefix='flua-release-tests-') as temporary:
        root = Path(temporary)
        (root / 'scripts').mkdir()
        (root / 'Makefile').write_text('.PHONY: release build\nrelease:\n\t@./scripts/release.sh\nbuild:\n\t@./scripts/build.sh\n')
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
import plistlib
import shutil

if 'FLUA_RELEASE_TEST_DIRECT_BUILD' not in os.environ:
    assert os.environ['FLUA_ENABLE_UPDATES'] == '1'
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
app_info = Path('build/Flua.app/Contents/Info.plist')
metadata = plistlib.loads(app_info.read_bytes())
metadata['SUPublicEDKey'] = 'test-public-key'
metadata['SUFeedURL'] = 'https://github.com/Eclipter/flua/releases/latest/download/appcast.xml'
metadata['SURequireSignedFeed'] = True
metadata['SUVerifyUpdateBeforeExtraction'] = True
app_info.write_bytes(plistlib.dumps(metadata))
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
        sparkle = root / 'sparkle'
        sparkle_bin = sparkle / 'bin'
        sparkle_bin.mkdir(parents=True)
        (root / 'scripts/sparkle.sh').write_text(f'#!/bin/sh\nprintf "%s\\n" "{sparkle}"\n')
        (root / 'scripts/sparkle.sh').chmod(0o755)
        (sparkle_bin / 'generate_keys').write_text('''#!/usr/bin/env python3
import os
if os.environ['FLUA_RELEASE_TEST_FAIL'] == 'keys':
    raise SystemExit(1)
print('wrong-public-key' if os.environ['FLUA_RELEASE_TEST_FAIL'] == 'wrong-key' else 'test-public-key')
''')
        (sparkle_bin / 'generate_keys').chmod(0o755)
        (sparkle_bin / 'generate_appcast').write_text('''#!/usr/bin/env python3
import os
from pathlib import Path
import sys

args = sys.argv[1:]
assert args[args.index('--account') + 1] == 'local.flua.desktop'
assert args[args.index('--maximum-deltas') + 1] == '0'
prefix = args[args.index('--download-url-prefix') + 1]
assert prefix.startswith('https://github.com/Eclipter/flua/releases/download/v')
output = Path(args[args.index('-o') + 1])
if os.environ['FLUA_RELEASE_TEST_FAIL'] == 'appcast':
    output.write_text('<rss>partial')
    raise SystemExit(1)
length = output.with_name('Flua.zip').stat().st_size
output.write_text('<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">'
                  f'<channel><item><enclosure url="{prefix}Flua.zip" length="{length}" '
                  'sparkle:edSignature="signed" /></item></channel></rss>')
''')
        (sparkle_bin / 'generate_appcast').chmod(0o755)
        (sparkle_bin / 'sign_update').write_text('''#!/usr/bin/env python3
import os
from pathlib import Path
import sys

assert sys.argv[1:4] == ['--account', 'local.flua.desktop', '--verify']
assert Path(sys.argv[4]).is_file()
if Path(sys.argv[4]).name == 'Flua.zip':
    assert sys.argv[5:] == ['signed']
    if os.environ['FLUA_RELEASE_TEST_FAIL'] == 'verify':
        raise SystemExit(1)
''')
        (sparkle_bin / 'sign_update').chmod(0o755)
        (fake_bin / 'mv').write_text('''#!/usr/bin/env python3
import os
import sys

if (os.environ['FLUA_RELEASE_TEST_FAIL'] == 'publish' and sys.argv[-1] == 'dist/appcast.xml'
        and '/previous/' not in sys.argv[-2]):
    raise SystemExit(1)
os.execv('/bin/mv', sys.argv)
''')
        (fake_bin / 'mv').chmod(0o755)
        archive = root / 'dist/Flua.zip'
        feed = root / 'dist/appcast.xml'
        archive.parent.mkdir()
        archive.write_bytes(b'previous archive')
        feed.write_bytes(b'previous feed')
        originals_assets = (archive.read_bytes(), feed.read_bytes())
        environment = dict(os.environ, PATH=f'{fake_bin}:{os.environ["PATH"]}',
                           FLUA_APP_PATH='/invalid/test-app', FLUA_CATALOG_PATH='/invalid/test-catalog',
                           FLUA_WALLPAPER_IDENTIFIER='invalid.test.provider', FLUA_RELEASE_TEST_FAIL=failure)
        if failure == 'success':
            build_environment = {key: value for key, value in environment.items() if key not in (
                'FLUA_APP_PATH', 'FLUA_CATALOG_PATH', 'FLUA_WALLPAPER_IDENTIFIER')}
            build_environment['FLUA_RELEASE_TEST_DIRECT_BUILD'] = '1'
            subprocess.run(['make', 'build'], cwd=root, env=build_environment, check=True)
            assert all((root / relative).read_bytes() == data for relative, data in originals.items())
            assert (archive.read_bytes(), feed.read_bytes()) == originals_assets
        result = subprocess.run(['make', 'release'], cwd=root, env=environment,
                                capture_output=True, text=True)
        assert (result.returncode == 0) == (failure == 'success'), result.stdout + result.stderr
        assert not list(archive.parent.glob('.release.*'))
        if failure != 'success':
            assert (archive.read_bytes(), feed.read_bytes()) == originals_assets
            assert all((root / relative).read_bytes() == data for relative, data in originals.items())
            assert (root / 'build-called').exists() == (failure not in ('mismatch', 'invalid'))
        else:
            major, minor, patch = original_info['CFBundleShortVersionString'].split('.')
            expected = (f'{major}.{minor}.{int(patch) + 1}', str(int(original_info['CFBundleVersion']) + 1))
            for relative in version_paths:
                info = plistlib.loads((root / relative).read_bytes())
                assert (info['CFBundleShortVersionString'], info['CFBundleVersion']) == expected
            with zipfile.ZipFile(archive) as packaged:
                assert len(packaged.namelist()) == 2
                app_info = plistlib.loads(packaged.read('Flua.app/Contents/Info.plist'))
                assert (app_info['CFBundleShortVersionString'], app_info['CFBundleVersion']) == expected, app_info
            assert b'sparkle:edSignature="signed"' in feed.read_bytes()
            assert feed.read_bytes() != originals_assets[1]
        print(f'PASS: release {failure}')
