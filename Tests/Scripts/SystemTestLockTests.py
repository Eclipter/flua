#!/usr/bin/env python3
import os
import signal
from pathlib import Path
import subprocess
import sys
import tempfile
import time

source = Path(__file__).resolve().parents[2]
lock_script = source / 'scripts/system-test-lock.py'
with tempfile.TemporaryDirectory(prefix='flua-system-test-lock-') as temporary:
    root = Path(temporary)
    temp_dir = root / 'tmp'
    temp_dir.mkdir()
    environment = dict(os.environ, TMPDIR=str(temp_dir),
                       FLUA_SYSTEM_TEST_LOCK_PATH=str(root / 'system-test.lock'))
    started = root / 'first-started'
    finished = root / 'first-finished'
    second_started = root / 'second-started'
    first_code = (
        'from pathlib import Path; import time; '
        f'Path({str(started)!r}).touch(); time.sleep(0.8); Path({str(finished)!r}).touch()'
    )
    first = subprocess.Popen(
        [sys.executable, str(lock_script), 'first check', sys.executable, '-c', first_code],
        env=environment,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    deadline = time.monotonic() + 3
    while not started.exists() and time.monotonic() < deadline:
        time.sleep(0.01)
    assert started.exists(), 'first check did not start'

    second_code = (
        'from pathlib import Path; '
        f'assert Path({str(finished)!r}).exists(); Path({str(second_started)!r}).touch()'
    )
    second = subprocess.run(
        [sys.executable, str(lock_script), 'second check', sys.executable, '-c', second_code],
        env=environment,
        capture_output=True,
        text=True,
        check=False,
        timeout=5,
    )
    first_output, first_error = first.communicate(timeout=5)
    assert first.returncode == 0, first_error or first_output
    assert second.returncode == 0, second.stderr or second.stdout
    assert 'Waiting for Flua system-test lock held by' in second.stdout
    assert finished.exists() and second_started.exists()

    failure = subprocess.run(
        [sys.executable, str(lock_script), 'failing check', sys.executable, '-c', 'raise SystemExit(7)'],
        env=environment,
        check=False,
    )
    assert failure.returncode == 7
    after_failure = subprocess.run(
        [sys.executable, str(lock_script), 'after failure', sys.executable, '-c', 'pass'],
        env=environment,
        check=False,
        timeout=5,
    )
    assert after_failure.returncode == 0

    nested_code = (
        'import subprocess, sys; '
        f'raise SystemExit(subprocess.run([{sys.executable!r}, {str(lock_script)!r}, '
        f'"nested check", {sys.executable!r}, "-c", "pass"]).returncode)'
    )
    nested = subprocess.run(
        [sys.executable, str(lock_script), 'outer check', sys.executable, '-c', nested_code],
        env=environment,
        check=False,
        timeout=5,
    )
    assert nested.returncode == 0

    ready_file = root / 'observer-ready'
    start_file = root / 'observer-start'
    nested_gate_code = (
        'import subprocess, sys; '
        f'raise SystemExit(subprocess.run([{sys.executable!r}, {str(lock_script)!r}, '
        f'"nested gated check", {sys.executable!r}, "-c", "pass"]).returncode)'
    )
    observed_command = subprocess.Popen(
        [sys.executable, str(lock_script), 'observed check', sys.executable, '-c', nested_gate_code],
        env=dict(environment, FLUA_SYSTEM_TEST_LOCK_READY_FILE=str(ready_file),
                 FLUA_SYSTEM_TEST_LOCK_START_FILE=str(start_file)),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    deadline = time.monotonic() + 3
    while not ready_file.exists() and time.monotonic() < deadline:
        time.sleep(0.01)
    assert ready_file.exists(), 'lock holder did not publish observer readiness'
    assert observed_command.poll() is None
    start_file.touch()
    observed_command.communicate(timeout=5)
    assert observed_command.returncode == 0

    child_pid_file = root / 'interrupted-child-pid'
    child_code = (
        'from pathlib import Path; import os, time; '
        f'Path({str(child_pid_file)!r}).write_text(str(os.getpid())); time.sleep(60)'
    )
    interrupted = subprocess.Popen(
        [sys.executable, str(lock_script), 'interrupted check', sys.executable, '-c', child_code],
        env=environment,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    deadline = time.monotonic() + 3
    while not child_pid_file.exists() and time.monotonic() < deadline:
        time.sleep(0.01)
    assert child_pid_file.exists(), 'interruptible check did not start'
    interrupted.terminate()
    interrupted.wait(timeout=5)
    assert interrupted.returncode == 128 + signal.SIGTERM
    after_termination = subprocess.run(
        [sys.executable, str(lock_script), 'after termination', sys.executable, '-c', 'pass'],
        env=environment,
        check=False,
        timeout=5,
    )
    assert after_termination.returncode == 0

    cleanup_file = root / 'nested-cleanup-finished'
    nested_started = root / 'nested-cleanup-started'
    nested_helper_pid_file = root / 'nested-helper-pid'
    signal_count_file = root / 'nested-signal-count'
    nested_child_code = (
        'from pathlib import Path\n'
        'import signal, time\n'
        f'cleanup = Path({str(cleanup_file)!r})\n'
        f'signal_count = Path({str(signal_count_file)!r})\n'
        'def stop(*_):\n'
        '    count = int(signal_count.read_text()) if signal_count.exists() else 0\n'
        '    signal_count.write_text(str(count + 1))\n'
        '    time.sleep(0.4)\n'
        '    cleanup.touch()\n'
        '    raise SystemExit(0)\n'
        'signal.signal(signal.SIGTERM, stop)\n'
        f'Path({str(nested_started)!r}).touch()\n'
        'time.sleep(60)\n'
    )
    nested_command = (
        'import subprocess, sys\n'
        'from pathlib import Path\n'
        f'nested = subprocess.Popen([{sys.executable!r}, {str(lock_script)!r}, '
        f'"nested cleanup", {sys.executable!r}, "-c", {nested_child_code!r}])\n'
        f'Path({str(nested_helper_pid_file)!r}).write_text(str(nested.pid))\n'
        'raise SystemExit(nested.wait())\n'
    )
    interrupted_nested = subprocess.Popen(
        [sys.executable, str(lock_script), 'outer interrupted check', sys.executable, '-c', nested_command],
        env=environment,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    deadline = time.monotonic() + 3
    while (not nested_started.exists() or not nested_helper_pid_file.exists()) and time.monotonic() < deadline:
        time.sleep(0.01)
    assert nested_started.exists(), 'nested cleanup check did not start'
    assert nested_helper_pid_file.exists(), 'nested helper PID was not published'
    os.kill(int(nested_helper_pid_file.read_text()), signal.SIGTERM)
    interrupted_nested.wait(timeout=5)
    assert cleanup_file.exists(), 'outer lock released before nested cleanup finished'
    assert signal_count_file.read_text() == '1', 'nested cleanup received repeated termination signals'

print('PASS: system-test lock queues checks and releases after failure or termination')
