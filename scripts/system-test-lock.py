#!/usr/bin/env python3
import fcntl
import json
import os
from pathlib import Path
import secrets
import signal
import subprocess
import sys
import time

lock_path = Path(os.environ.get('FLUA_SYSTEM_TEST_LOCK_PATH', f'/tmp/flua-system-test-{os.getuid()}.lock'))


def run_locked(command, label, lock_fd, owner=None):
    environment = dict(os.environ)
    pass_fds = ()
    if lock_fd is not None:
        environment['FLUA_SYSTEM_TEST_LOCK_FD'] = str(lock_fd)
        pass_fds = (lock_fd,)
    if owner is not None:
        environment['FLUA_SYSTEM_TEST_LOCK_TOKEN'] = owner['token']
        os.lseek(lock_fd, 0, os.SEEK_SET)
        os.ftruncate(lock_fd, 0)
        os.write(lock_fd, json.dumps(owner).encode())
        os.fsync(lock_fd)
        print(f'Acquired Flua system-test lock for {label}.', flush=True)
    ready_file = environment.pop('FLUA_SYSTEM_TEST_LOCK_READY_FILE', None)
    if ready_file:
        Path(ready_file).write_text('acquired\n')
    start_file = environment.pop('FLUA_SYSTEM_TEST_LOCK_START_FILE', None)
    if start_file:
        deadline = time.monotonic() + 30
        while not Path(start_file).exists() and time.monotonic() < deadline:
            time.sleep(0.02)
        if not Path(start_file).exists():
            print('Observer did not release the system-test start gate.', file=sys.stderr)
            return 2
        Path(start_file).unlink()
    child = subprocess.Popen(command, env=environment, pass_fds=pass_fds, start_new_session=True)

    received_signals = []

    def stop_child(signal_number, _frame):
        if received_signals:
            return
        received_signals.append(signal_number)
        try:
            os.killpg(child.pid, signal_number)
        except ProcessLookupError:
            pass

    previous = {sig: signal.signal(sig, stop_child) for sig in (signal.SIGINT, signal.SIGTERM)}
    try:
        status = child.wait()
        while True:
            try:
                os.killpg(child.pid, 0)
            except ProcessLookupError:
                break
            time.sleep(0.05)
        return 128 + received_signals[0] if received_signals else status
    finally:
        for sig, handler in previous.items():
            signal.signal(sig, handler)


def inherited_lock():
    value = os.environ.get('FLUA_SYSTEM_TEST_LOCK_FD')
    if value is None:
        return None
    try:
        fd = int(value)
        inherited = os.fstat(fd)
        expected = lock_path.stat()
        if (inherited.st_dev, inherited.st_ino) != (expected.st_dev, expected.st_ino):
            return None
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return fd
    except (OSError, ValueError):
        return None


def inherited_owner():
    token = os.environ.get('FLUA_SYSTEM_TEST_LOCK_TOKEN')
    if token is None:
        return False
    try:
        owner = json.loads(lock_path.read_text())
        if owner.get('token') != token:
            return False
        os.kill(owner['pid'], 0)
        return True
    except (OSError, KeyError, TypeError, json.JSONDecodeError, ValueError):
        return False


def main():
    if sys.argv[1:] == ['--is-locked']:
        return 0 if inherited_owner() else 1
    if len(sys.argv) < 3:
        print(f'Usage: {sys.argv[0]} LABEL COMMAND [ARG ...]', file=sys.stderr)
        return 2

    label, command = sys.argv[1], sys.argv[2:]
    inherited = inherited_lock()
    if inherited is not None:
        return run_locked(command, label, inherited)
    if inherited_owner():
        return run_locked(command, label, None)

    started = time.monotonic()
    last_notice = None
    with lock_path.open('a+') as lock:
        while True:
            try:
                fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                elapsed = int(time.monotonic() - started)
                if last_notice is None or elapsed - last_notice >= 5:
                    lock.seek(0)
                    try:
                        owner = json.loads(lock.read())
                    except (json.JSONDecodeError, OSError):
                        owner = {}
                    holder = (
                        'PID {} ({} in {})'.format(owner['pid'], owner['label'], owner['directory'])
                        if owner else 'another process'
                    )
                    print(f'Waiting for Flua system-test lock held by {holder}; waited {elapsed}s.', flush=True)
                    last_notice = elapsed
                time.sleep(0.5)

        owner = {
            'pid': os.getpid(),
            'label': label,
            'started': time.strftime('%Y-%m-%d %H:%M:%S %z'),
            'directory': str(Path.cwd()),
            'token': secrets.token_hex(24),
        }
        return run_locked(command, label, lock.fileno(), owner)


if __name__ == '__main__':
    raise SystemExit(main())
