"""Bounded file handshakes for fixture states observed by the test runner."""
import os
from pathlib import Path
import time


def checkpoint(stage):
    directory = os.environ.get('ZPG_TEST_SYNC')
    if directory is None:
        return
    path = Path(directory) / str(stage)
    deadline = time.monotonic() + 10
    while not path.exists():
        if time.monotonic() >= deadline:
            raise TimeoutError(f'test did not acknowledge stage {stage}')
        time.sleep(.01)
