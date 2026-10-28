#!/usr/bin/env python3
"""Verify clean removes generated products and preserves source files."""

from pathlib import Path
import shutil
import subprocess
import tempfile


source = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix='flua-clean-tests-') as temporary:
    root = Path(temporary)
    shutil.copy2(source / 'Makefile', root / 'Makefile')
    outputs = ('.build', 'build', 'dist', 'Sources/WallpaperExtension/Built')
    for directory in outputs:
        path = root / directory
        path.mkdir(parents=True)
        (path / 'generated').write_bytes(b'generated output')
    preserved = root / 'Sources/WallpaperExtension/Provider.m'
    preserved.write_bytes(b'source fixture')
    for _ in range(2):
        subprocess.run(['make', 'clean'], cwd=root, check=True)
        assert all(not (root / directory).exists() for directory in outputs)
        assert preserved.read_bytes() == b'source fixture'
    print('PASS: clean removes all default build outputs and preserves sources')
