#!/usr/bin/env python3
"""Check the Swift whitespace policy without rewriting source files."""

from pathlib import Path
import subprocess
import sys


ROOT = Path(__file__).resolve().parent.parent


def violations(data):
    try:
        text = data.decode('utf-8')
    except UnicodeDecodeError:
        return ['file must be UTF-8']
    errors = []
    if text and not text.endswith('\n'):
        errors.append('file must end with a newline')
    for number, line in enumerate(text.split('\n'), 1):
        if '\r' in line:
            errors.append(f'{number}: use LF line endings')
        if '\t' in line:
            errors.append(f'{number}: use spaces instead of tabs')
        if line.rstrip(' \t\r') != line.rstrip('\r'):
            errors.append(f'{number}: remove trailing whitespace')
    return errors


def main():
    files = subprocess.check_output(
        ['git', 'ls-files', '-z', '--', '*.swift'], cwd=ROOT
    ).decode('utf-8').split('\0')
    failed = False
    for name in filter(None, files):
        path = ROOT / name
        # Deleted tracked files do not need formatting.
        if not path.exists():
            continue
        for error in violations(path.read_bytes()):
            print(f'{name}: {error}', file=sys.stderr)
            failed = True
    if not failed:
        print('Swift whitespace policy passed.')
    return int(failed)


if __name__ == '__main__':
    sys.exit(main())
