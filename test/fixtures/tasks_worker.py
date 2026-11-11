"""Parallel task barriers and progress reports for integration checks."""
import os
from pathlib import Path
import signal
import struct
import sys
import time
from sync import checkpoint


def wait_for(path):
    deadline = time.monotonic() + 10
    while not path.exists():
        if time.monotonic() >= deadline:
            raise TimeoutError(f'task did not create {path}')
        time.sleep(.01)


mode, directory, name = sys.argv[1:4]
root = Path(directory)
if mode == 'barrier':
    (root / name).touch()
    wait_for(root / sys.argv[4])
    os.write(1, f'{name} stdout\n'.encode())
    os.write(2, f'{name} stderr\n'.encode())
    (root / (name + '.done')).touch()
    sys.exit(int(sys.argv[5]))
elif mode in ('hold', 'family'):
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    if mode == 'family':
        child = os.fork()
        if child == 0:
            while True:
                time.sleep(1)
        (root / (name + '.child')).write_text(str(child))
    (root / name).write_text(str(os.getpid()))
    while True:
        time.sleep(1)
elif mode == 'winner':
    for other in sys.argv[5:]:
        wait_for(root / other)
    sys.exit(int(sys.argv[4]))
elif mode == 'progress':
    if 'ZIG_PROGRESS' in os.environ:
        os.write(int(os.environ['ZIG_PROGRESS']), struct.pack(
            '<BII120sB', 1, 1, 4, name.encode(), 255))
    checkpoint(sys.argv[4] if len(sys.argv) > 4 else 'tasks-visible')
