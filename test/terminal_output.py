"""Differential terminal checks with a handshake at every output boundary.

No third-party Python packages are needed. Each child write is held until the
parent has observed it and allowed progress redraws. This tests live display
states as well as the final screen and byte stream.
"""
import errno
import fcntl
import json
import os
from pathlib import Path
import pty
import select
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import termios
import time
import unittest

from terminal_model import Terminal, check_model, OVERLAY, output_without_overlay, feed_output
from fixture_sync import FixtureSync

EXE = str(Path(sys.argv.pop(1)).resolve())
WORKER = str(Path(__file__).parent / 'fixtures' / 'terminal_worker.py')


def cases(cols):
    # An independent expected screen is built from these original bytes alone.
    # Hold at the right margin and after every type of cursor operation.
    full = b'x' * cols
    chunks = [b'log\r\n' * 12, b'long status\rOK', b'\r\x1b[2Kdone\r\n']
    for control in (b'\b', b'\x1b[D', b'\x1b[A', b'\x1b[B', b'\n',
                    b'\x1bD', b'\x1b[K', b'\x1b[1K', b'\x1b[2K', b'\t'):
        chunks += [b'\x1bD\x1bD\x1bD\x1b[3A' + full, control, b'X\r\n']
    chunks += [
        b'footer old\r\nitems 0/2\r\x1b[A',
        b'\x1b[', b'0Kfooter new\x1b[E',
        b'\x1b[2Kitems 2/2\x1b[F', b'\x1b[E\r\n',
        b'alpha\r\nbeta\r\ngamma\x1b[2F', b'\x1b[0Jshort', b'\r\n',
        b'abc\x1b[0GQ\x1b[2CR\x1b[2DS\r\n',
        b'one\vtwo\fthree\r\n',
        b'\x1b[31', b'mred', b'\x1b[0m\r\n',
        b'wide: \xe7', b'\x95', b'\x8c', ' café e\u0301'.encode(), b'!\r\n',
        b'\x1b]0;ignored title', b'\x1b', b'\\', b'title done\r\n',
        b'\x1b]0;other title', b'\a',
        b'\x1bPignored\a', b'still ignored', b'\x1b\\',
        b'\x1b[123', b'\x18', b'cancelled\r\n',
        b'\x1b[99', b'\x1b[2G', b'restarted\r\n',
        b'\x1b[\r2C', b'C0 inside CSI\r\n',
    ]
    # A saved cursor slot remains valid after restore. Never let zpg's own
    # scrolling change the screen row addressed by a second restore.
    for save, restore in ((b'\x1b7', b'\x1b8'), (b'\x1b[s', b'\x1b[u')):
        chunks += [b'\x1bD\x1bD\x1b[2Asaved: ' + save, b'\r\nfooter', restore, b'one', restore,
                   b'two', b'\r\n\x1b[2Kafter save\r\n']
    chunks += [b'finished\r\n']
    return chunks


class FixtureSynchronization(unittest.TestCase):
    def test_split_output_and_repeated_markers(self):
        sync = FixtureSync([(1, rb'ready'), (2, rb'ready')])
        try:
            directory = Path(sync.directory.name)
            sync.observe(b'rea')
            self.assertFalse((directory / '1').exists())
            sync.observe(b'ready')
            self.assertTrue((directory / '1').exists())
            sync.observe(b'ready')
            self.assertFalse((directory / '2').exists())
            sync.observe(b'readyready')
            self.assertTrue((directory / '2').exists())
        finally:
            sync.close()

    def test_interrupted_stage_stays_open(self):
        sync = FixtureSync([(1, None)])
        try:
            sync.observe(b'any output')
            self.assertFalse((Path(sync.directory.name) / '1').exists())
        finally:
            sync.close()

    def test_buffered_markers_cannot_release_a_later_stage(self):
        sync = FixtureSync([(1, rb'ready'), (2, rb'ready')])
        try:
            directory = Path(sync.directory.name)
            sync.observe(b'readyready')
            self.assertTrue((directory / '1').exists())
            sync.observe(b'readyready')
            self.assertFalse((directory / '2').exists())
            sync.observe(b'readyreadyready')
            self.assertTrue((directory / '2').exists())
        finally:
            sync.close()


class TerminalOutput(unittest.TestCase):
    def run_case(self, chunks, *, renderer='bars', nested=False, destination=1,
                 progress_stream='stderr', shared=True, rows=8, cols=40,
                 convert=False, progress=True, interrupt=False, expected_lines=None):
        env = dict(os.environ, TERM='xterm-256color')
        for key in ('ZIG_PROGRESS', 'ZPG_NO_PROGRESS', 'UNICODE_PROGRESS_BAR', 'NO_COLOR'):
            env.pop(key, None)
        command = [EXE, '--name', '__overlay__', '--renderer', renderer,
                   '--progress-stream', progress_stream]
        if not progress:
            command += ['--no-progress']
        for _ in range(int(nested)):
            command += [EXE, '--name', '__overlay__']
        descriptors, masters = {}, {}
        process = None
        connection = None
        with tempfile.TemporaryDirectory(prefix='zpg-terminal-') as directory:
            path = str(Path(directory) / 'control.sock')
            plan = str(Path(directory) / 'chunks.json')
            Path(plan).write_text(json.dumps([
                dict(chunk, data=chunk['data'].hex()) if isinstance(chunk, dict)
                else chunk.hex() for chunk in chunks
            ]))
            with socket.socket(socket.AF_UNIX) as listener:
                listener.bind(path)
                listener.listen(1)
                listener.settimeout(5)
                try:
                    for fd in (1, 2):
                        if fd == 2 and shared:
                            descriptors[fd] = descriptors[1]
                            continue
                        master, slave = pty.openpty()
                        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', rows, cols, 0, 0))
                        attrs = termios.tcgetattr(slave)
                        if convert:
                            attrs[1] |= termios.OPOST | termios.ONLCR
                        else:
                            attrs[1] &= ~termios.OPOST
                        termios.tcsetattr(slave, termios.TCSANOW, attrs)
                        descriptors[fd] = slave
                        masters[master] = fd
                    models = {fd: Terminal(rows, cols) for fd in masters.values()}
                    baseline = {fd: Terminal(rows, cols) for fd in masters.values()}
                    boundaries = {fd: Terminal(rows, cols) for fd in masters.values()}
                    checked = {fd: 0 for fd in masters.values()}
                    captured = {fd: bytearray() for fd in masters.values()}
                    expected = {fd: bytearray() for fd in masters.values()}
                    process = subprocess.Popen(command + [sys.executable, WORKER, path, plan, str(destination)],
                                               stdin=subprocess.DEVNULL, stdout=descriptors[1],
                                               stderr=descriptors[2], env=env)
                    for slave in set(descriptors.values()):
                        os.close(slave)
                    descriptors.clear()
                    connection, _ = listener.accept()
                    connection.settimeout(5)
                    messages = connection.makefile('rb')
                    self.assertEqual(messages.readline(), b'ready\n')

                    def drain(duration):
                        until = time.monotonic() + duration
                        while masters and time.monotonic() < until:
                            ready, _, _ = select.select(list(masters), [], [], min(.005, max(0, until - time.monotonic())))
                            for master in ready:
                                try:
                                    data = os.read(master, 65536)
                                except OSError as error:
                                    if error.errno != errno.EIO:
                                        raise
                                    data = b''
                                fd = masters[master]
                                if data:
                                    captured[fd].extend(data)
                                    # Replay the capture so partial child sequences
                                    # remain visible at each handshake boundary.
                                    models[fd] = Terminal(rows, cols)
                                    feed_output(models[fd], bytes(captured[fd]))
                                else:
                                    os.close(master)
                                    del masters[master]

                    def compare(stage, final=False):
                        for fd, model in models.items():
                            context = (stage, renderer, nested, destination, progress_stream, shared, rows, cols, fd)
                            data = bytes(captured[fd])
                            self.assertEqual(output_without_overlay(data), bytes(expected[fd]), context)
                            # A byte-preserving stripper alone could hide an
                            # overlay inserted into OSC/CSI or a UTF-8 character.
                            # Check the original child state at every insertion.
                            for transaction in OVERLAY.finditer(data, checked[fd]):
                                boundary = boundaries[fd]
                                boundary.feed(data[checked[fd]:transaction.start()])
                                self.assertEqual(boundary.state, 'text', context)
                                self.assertEqual(boundary.decoder.getstate()[0], b'', context)
                                self.assertFalse(boundary.wrap, context)
                                checked[fd] = transaction.end()
                            self.assertFalse(any(model.history_overlay), context)
                            visible = [line for line, overlay in zip(model.lines(), model.history_overlay + model.overlay)
                                       if line and not overlay]
                            wanted = [line for line in baseline[fd].lines() if line]
                            self.assertEqual(visible, wanted, context)
                            self.assertEqual((len(model.history) + model.row, model.col, model.wrap, model.sgr),
                                             (len(baseline[fd].history) + baseline[fd].row, baseline[fd].col,
                                              baseline[fd].wrap, baseline[fd].sgr), context)
                            self.assertEqual(model.state, baseline[fd].state, context)
                            self.assertEqual(model.decoder.getstate(), baseline[fd].decoder.getstate(), context)
                            if final:
                                self.assertFalse(any(model.overlay), context)

                    # Hold the worker until progress reaches the terminal.
                    # Nested collectors can take longer than a fixed delay.
                    if progress and rows > 2 and cols > 1:
                        deadline = time.monotonic() + 3
                        def initial_progress():
                            # Nested labels can be clipped by tree indentation.
                            if not nested and rows >= 5 and cols >= 40:
                                return any('__overlay__' in line and '1/2' in line
                                           for model in models.values() for line in model.lines())
                            return any(any(model.overlay) for model in models.values())

                        while not initial_progress():
                            self.assertLess(time.monotonic(), deadline, 'missing initial progress')
                            drain(.01)
                    connection.sendall(b'!')
                    target = 1 if shared else destination
                    for index, chunk in enumerate(chunks):
                        self.assertEqual(messages.readline(), b'stage\n')
                        settings = chunk if isinstance(chunk, dict) else {}
                        chunk = settings.get('data', chunk)
                        data = chunk.replace(b'\n', b'\r\n') if convert else chunk
                        expected[target].extend(data)
                        baseline[target].feed(data)
                        frame_start = len(models[target].snapshots)
                        frame_counts = {fd: model.frames for fd, model in models.items()}
                        deadline = time.monotonic() + 3
                        while output_without_overlay(bytes(captured[target])) != bytes(expected[target]):
                            self.assertLess(time.monotonic(), deadline, ('missing child bytes', index))
                            drain(.01)
                        if 'frame_lines' in settings:
                            # Keep the worker at this stage until a complete
                            # redraw contains both its output and progress.
                            # A fixed sleep can miss this frame on a busy host.
                            deadline = time.monotonic() + 3
                            while not any(
                                all(line in frame for line in settings['frame_lines'])
                                and any('__overlay__' in line and '1/2' in line for line in frame)
                                for frame in models[target].snapshots[frame_start:]
                            ):
                                self.assertLess(time.monotonic(), deadline,
                                                ('missing progress frame', index, renderer, nested,
                                                 destination, models[target].snapshots[frame_start:]))
                                drain(.01)
                        drain(.15 if settings else (.045 if progress else .001))
                        if 'hidden' in settings:
                            # Progress packets arrive separately from child
                            # output. Shrinking also takes several snapshots.
                            # Hold this stage until the display has caught up.
                            deadline = time.monotonic() + 3
                            while any(any(model.overlay) for model in models.values()) != (not settings['hidden']):
                                self.assertLess(time.monotonic(), deadline,
                                                ('progress visibility timeout', index, renderer,
                                                 settings['hidden']))
                                drain(.01)
                        compare(index)
                        if settings.get('continuous'):
                            frames = models[target].snapshots[frame_start:]
                            self.assertTrue(frames)
                            self.assertTrue(all(any('__overlay__' in line for line in frame)
                                                for frame in frames), frames)
                        if settings.get('unchanged'):
                            self.assertEqual({fd: model.frames for fd, model in models.items()},
                                             frame_counts)
                        if 'hidden' in settings:
                            self.assertEqual(any(any(model.overlay) for model in models.values()),
                                             not settings['hidden'], index)
                        if interrupt and index == len(chunks) - 1:
                            process.send_signal(signal.SIGINT)
                            break
                        connection.sendall(b'!')
                    deadline = time.monotonic() + 5
                    while masters:
                        self.assertLess(time.monotonic(), deadline, 'terminal drain timeout')
                        drain(.02)
                    self.assertEqual(process.wait(timeout=3), 130 if interrupt else 0)
                    compare('exit', final=True)
                    if expected_lines is not None:
                        self.assertEqual([line for line in models[target].lines() if line], expected_lines)
                    if progress and rows > 2 and cols > 1:
                        self.assertTrue(any(model.frames for model in models.values()))
                    messages.close()
                finally:
                    if process is not None and process.poll() is None:
                        process.kill()
                        process.wait()
                    if connection is not None:
                        connection.close()
                    for master in masters:
                        os.close(master)
                    for slave in set(descriptors.values()):
                        os.close(slave)

    def test_model_golden_cases(self):
        check_model()

    def test_log_updates_do_not_present_a_blank_progress_frame(self):
        for renderer in ('bars', 'tree'):
            for destination in (1, 2):
                with self.subTest(renderer=renderer, destination=destination):
                    self.run_case([
                        dict(data=b'ready\r\n', frame_lines=['ready']),
                        dict(data=b'first\r\n', continuous=True),
                        dict(data=b'second\r\n', continuous=True),
                        dict(data=b'partial', continuous=True),
                        dict(data=b' continued\r\n', continuous=True),
                    ], renderer=renderer, destination=destination)

    def test_unchanged_tree_does_not_redraw(self):
        self.run_case([
            dict(data=b'ready\r\n', frame_lines=['ready']),
            dict(data=b'', unchanged=True),
        ], renderer='tree')

    def test_other_terminal_output_does_not_redraw_tree(self):
        self.run_case([
            dict(data=b'first\r\n', unchanged=True),
            dict(data=b'second\r\n', unchanged=True),
        ], renderer='tree', shared=False, destination=1, progress_stream='stderr')

    def test_controls(self):
        for renderer in ('bars', 'tree'):
            for nested in (False, True):
                for destination in (1, 2):
                    with self.subTest(renderer=renderer, nested=nested, destination=destination):
                        self.run_case(cases(40), renderer=renderer, nested=nested,
                                      destination=destination,
                                      progress_stream='stdout' if destination == 1 else 'stderr')

    def test_control_frames(self):
        chunks = [
            b'log\n' * 10,
            dict(data=b'abcdefghij\rXY', frame_lines=['XYcdefghij']),
            b'\r\x1b[2Kbar 100%\n',
            dict(data=b'footer old\nitems 0/2\r\x1b[A',
                 frame_lines=['footer old', 'items 0/2']),
            b'\x1b[',
            b'2Kfooter done\x1b[B\r\x1b[2Kitems 2/2\x1b[A\r',
            b'\x1b[B\r\n',
        ]
        expected = ['log'] * 10 + ['bar 100%', 'footer done', 'items 2/2']
        for renderer in ('bars', 'tree'):
            for nested in (False, True):
                for destination in (1, 2):
                    with self.subTest(renderer=renderer, nested=nested, destination=destination):
                        self.run_case(chunks, renderer=renderer, nested=nested,
                                      destination=destination, cols=80, convert=True,
                                      expected_lines=expected)

    def test_separate_terminals(self):
        chunks = [b'first\r\n', b'long value\rOK', b'\x1b[2Kdone\r\n',
                  b'one\r\ntwo\r\x1b[A', b'\x1b[2Knew\x1b[E\r\n']
        for renderer in ('bars', 'tree'):
            for destination in (1, 2):
                for selected in ('stdout', 'stderr'):
                    with self.subTest(renderer=renderer, destination=destination, selected=selected):
                        self.run_case(chunks, renderer=renderer, destination=destination,
                                      progress_stream=selected, shared=False, nested=True)

    def test_each_byte_can_arrive_in_a_separate_write(self):
        data = b'\x1b[31mred\x1b[0m\rOK\r\n\x1b]0;title\x1b\\' + '界é'.encode() + b'\r\n'
        for renderer in ('bars', 'tree'):
            with self.subTest(renderer=renderer):
                self.run_case([bytes([byte]) for byte in data], renderer=renderer, nested=2)

    def test_saved_cursor_slot_survives_repeated_restores(self):
        for save, restore in ((b'\x1b7', b'\x1b8'), (b'\x1b[s', b'\x1b[u')):
            chunks = [b'log\r\n' * 12, b'\x1bD\x1b[Asaved: ' + save,
                      b'\r\nfooter', restore, b'one', restore, b'two', b'\x1b[E\r\n']
            with self.subTest(save=save):
                self.run_case(chunks)

    def test_small_terminals_and_wrapping(self):
        for rows, cols in ((1, 1), (2, 8), (3, 8), (8, 8), (8, 20), (24, 80)):
            chunks = [b'first\r\n', b'x' * cols, b'\b', b'Z', b'\r\n', b'last\r\n']
            with self.subTest(rows=rows, cols=cols):
                self.run_case(chunks, rows=rows, cols=cols)

    def test_growing_progress_is_cleared_when_a_footer_leaves_too_little_space(self):
        for renderer in ('bars', 'tree'):
            with self.subTest(renderer=renderer):
                self.run_case([
                    dict(data=b'row0\r\nrow1\r\nrow2\r\nrow3\r\nrow4\r\x1b[4A', hidden=False),
                    dict(data=b'', nodes=4, hidden=True),
                    dict(data=b'', nodes=1, hidden=False),
                    b'\x1b[4B\r\n',
                ], renderer=renderer)

    def test_reverse_index_preserves_the_row_below(self):
        self.run_case([b'first', b'\x1bM', b'second', b'\x1b[E', b'\r\nend\r\n'])

    def test_terminal_newline_conversion(self):
        # OPOST changes only LF on the real destination, never captured PTY bytes.
        chunks = [b'line\n', b'abc\n', b'12345678', b'\n', b'X\n', b'\r\nfinal\n']
        for convert in (False, True):
            with self.subTest(convert=convert):
                self.run_case(chunks, cols=8, convert=convert)

    def test_no_progress_preserves_controls_and_bytes(self):
        chunks = [b'long status\rOK', b'\r\n', b'\x1b[31mred\x1b[0m',
                  b'\r\n', b'\x1b]0;title\a', '界é'.encode(), b'\r\n']
        for destination in (1, 2):
            for shared in (False, True):
                with self.subTest(destination=destination, shared=shared):
                    self.run_case(chunks, destination=destination, shared=shared, progress=False, nested=True)

    def test_exit_with_unfinished_output(self):
        for tail in (b'partial', b'working\r', b'\x1b', b'\x1b[12', b'\x1b]title', b'\xe7', b'\x1b7'):
            for interrupt in (False, True):
                with self.subTest(tail=tail, interrupt=interrupt):
                    self.run_case([b'line\r\n', tail], interrupt=interrupt)



if __name__ == '__main__':
    unittest.main()
