#!/usr/bin/env python3
"""Exercise the lint command in a disposable Git repository."""

from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[2] / 'scripts/lint.py'


class LintTests(unittest.TestCase):
    def test_policy_and_file_selection(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'scripts').mkdir()
            shutil.copyfile(SCRIPT, root / 'scripts/lint.py')
            subprocess.run(['git', 'init', '-q', directory], check=True)
            source = root / 'Source with spaces.swift'
            source.write_bytes(b'func example() {\n    print("hello")\n}\n')
            (root / 'Ignored.swift').write_bytes(b'\tignored\r\n')
            (root / '.gitignore').write_text('Ignored.swift\n')
            subprocess.run(['git', '-C', directory, 'add', '.'], check=True)

            def lint():
                return subprocess.run(
                    ['python3', str(root / 'scripts/lint.py')],
                    capture_output=True, text=True, check=False
                )

            self.assertEqual(lint().returncode, 0)
            for contents, diagnostic in [
                (b'let value = 1', 'end with a newline'),
                (b'\tlet value = 1\n', 'spaces instead of tabs'),
                (b'let value = 1 \n', 'trailing whitespace'),
                (b'let value = 1\r\n', 'LF line endings'),
                (b'\xff\n', 'UTF-8'),
            ]:
                with self.subTest(diagnostic=diagnostic):
                    source.write_bytes(contents)
                    result = lint()
                    self.assertEqual(result.returncode, 1)
                    self.assertIn(diagnostic, result.stderr)
                    self.assertIn(source.name, result.stderr)
                    self.assertEqual(source.read_bytes(), contents)
            source.unlink()
            self.assertEqual(lint().returncode, 0)
            source.write_bytes(b'')
            self.assertEqual(lint().returncode, 0)


if __name__ == '__main__':
    unittest.main()
