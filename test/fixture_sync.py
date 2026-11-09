"""Release fixture stages only after their output reaches the test runner."""
from pathlib import Path
import re
import tempfile


class FixtureSync:
    def __init__(self, checkpoints):
        self.directory = tempfile.TemporaryDirectory() if checkpoints else None
        self.pending = iter(checkpoints or [])
        self.current = next(self.pending, None)
        self.offset = 0

    def environment(self):
        return {'ZPG_TEST_SYNC': self.directory.name} if self.directory else {}

    def observe(self, data):
        if self.current is None:
            return
        stage, pattern = self.current
        if pattern is None:  # Hold this state until the test interrupts the child.
            return
        match = re.search(pattern, data[self.offset:], re.S)
        if match is not None:
            self.offset += match.end()
            (Path(self.directory.name) / str(stage)).touch()
            self.current = next(self.pending, None)

    def close(self):
        if self.directory:
            self.directory.cleanup()
