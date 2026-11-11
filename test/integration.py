"""Behavior checks for pipes, process cleanup, and terminal progress."""
import errno
import json
import fcntl
import struct
import termios
import os
import pathlib
import pty
import re
import select
import signal
import subprocess
import sys
import tempfile
import time
from terminal_model import Terminal, feed_output, output_without_overlay
from fixture_sync import FixtureSync

exe = str(pathlib.Path(sys.argv[1]).resolve())
render_probe = str(pathlib.Path(sys.argv[2]).resolve())
fixture = str(pathlib.Path(__file__).parent / 'fixtures' / 'worker.py')
guess_fixture = str(pathlib.Path(__file__).parent / 'fixtures' / 'guess_worker.py')
report_demo = str(pathlib.Path(__file__).parent.parent / 'examples' / 'report-demo.sh')
env = dict(os.environ, PATH=str(pathlib.Path(exe).parent) + os.pathsep + os.environ['PATH'])
env.pop('UNICODE_PROGRESS_BAR', None)
env.pop('ZPG_NO_PROGRESS', None)
env.pop('ZPG_TEST_SYNC', None)

# The full demo sleeps for about eight seconds before terminal updates and
# process cleanup. Allow extra time for delayed wakeups on CI runners.
MOCK_TIMEOUT = 30

def read_pid(stream, timeout=5):
    deadline = time.monotonic() + timeout
    data = bytearray()
    while b'\n' not in data:
        remaining = deadline - time.monotonic()
        assert remaining > 0, ('worker did not report its PID', data)
        ready, _, _ = select.select([stream], [], [], remaining)
        assert ready, ('worker did not report its PID', data)
        chunk = os.read(stream.fileno(), 4096)
        assert chunk, ('worker exited before reporting its PID', data)
        data.extend(chunk)
    return int(data.strip())

def capture_output(*args, code=0):
    p = subprocess.run([exe, *args], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                       stdin=subprocess.DEVNULL, env=env, timeout=15)
    assert p.returncode == code, (args, p.returncode, p.stderr)
    return p

def run(*args, code=0, stream=None):
    p = capture_output(*args, code=code)
    stream = stream or ('stderr' if code in (1, 2) else 'stdout')
    other = p.stderr if stream == 'stdout' else p.stdout
    assert other == b'', other
    return getattr(p, stream)

def worker(mode, *args, code=0, stream=None):
    return run('--name', 'worker', sys.executable, fixture, mode, *args, code=code, stream=stream)

for args in [(), ('--bad',), ('--guessa', 'true'), ('--name',), ('--mock', 'true'),
             ('--guess',), ('--guess', '--mock'),
             ('--guess', '--report', '1', '2'),
             ('--renderer',), ('--renderer', 'bad', 'true'),
             ('--progress-stream',), ('--progress-stream', 'bad', 'true'),
             ('--bar-style',), ('--spinner-style',),
             ('--bar-style', 'bad', 'true'),
             ('--bar-style', '#\n', 'true'),
             ('--bar-style', '#\u202e', 'true'),
             ('--spinner-style', '', 'true'),
             ('--spinner-style', '\x1b[2J', 'true'),
             ('--spinner-style', '\u2066', 'true')]:
    run(*args, code=2)
assert b'Usage:' in run('--help', stream='stderr')
# A report is silent without a supervisor, including redirected scripts.
report_env = dict(env)
report_env.pop('ZIG_PROGRESS', None)
p = subprocess.run([exe, '--report', '1', '2'], env=report_env,
                   capture_output=True, timeout=5)
assert (p.returncode, p.stdout, p.stderr) == (0, b'', b'')
for args in [('--report',), ('--report', '1'), ('--report', '-1', '2'),
             ('--report', '1', '4294967295'), ('--report', '1', '2', 'true')]:
    run(*args, code=2)
# Inspect the wire packet independently of the renderer. Separate reporter
# processes share one inherited pipe, as they do in a shell script.
read_fd, write_fd = os.pipe()
try:
    for completed, total, name in [(1, 4, ''), (3, 4, 'compile'), (5, 0, 'files')]:
        p = subprocess.run([exe, '--report', str(completed), str(total), '--name', name],
                           env=dict(report_env, ZIG_PROGRESS=str(write_fd)),
                           pass_fds=(write_fd,), capture_output=True, timeout=5)
        assert (p.returncode, p.stdout, p.stderr) == (0, b'', b'')
        ready, _, _ = select.select([read_fd], [], [], 2)
        assert ready, 'report did not write a snapshot'
        packet = os.read(read_fd, 4096)
        assert len(packet) == 130 and packet[0] == 1 and packet[-1] == 255, packet
        assert struct.unpack('<II', packet[1:9]) == (completed, total)
        assert packet[9:129].split(b'\0', 1)[0] == name.encode()
finally:
    os.close(read_fd)
    os.close(write_fd)
script = 'set -e; zpg --report 1 4; printf "script log\\n"; zpg --report 4 4'
assert run('sh', '-c', script) == b'script log\n'
assert run('--no-progress', 'sh', '-c', script) == b'script log\n'
demo_result = capture_output('--name', 'shell demo', 'sh', report_demo)
demo_log = demo_result.stdout
assert demo_result.stderr == (b'shell demo: discover complete\n'
                              b'shell demo: build complete\n'
                              b'shell demo: publish complete\n')
for worker_name in (b'indexer', b'compiler', b'uploader'):
    assert worker_name + b': finish complete' in demo_log
assert b'shell demo: complete' in demo_log
run('zpg-command-that-does-not-exist', code=1)
log = worker('args', '--flag', 'a b', '', '$(false)')
assert b"['--flag', 'a b', '', '$(false)']" in log
assert b"stdin=''" in log and b'tty=(False, False)' in log
assert run('--', sys.executable, fixture, 'args', '--help') == run(
    sys.executable, fixture, 'args', '--help')
# Neither pipe may gain labels, newlines, or a final status message.
payload = b'first\n\nlast\r\x1b[31m\x00' + bytes(range(256)) + b'x' * 20000
# Input must survive pipes, file redirection, and nested supervisors unchanged.
input_payload = payload * 16
for prefix in ([], ['--no-progress'], [exe]):
    command = [exe, *prefix, sys.executable, fixture, 'stdin']
    p = subprocess.run(command, input=input_payload, capture_output=True, env=env, timeout=15)
    assert (p.returncode, p.stdout, p.stderr) == (0, input_payload, b'')
    with tempfile.TemporaryFile() as source:
        source.write(input_payload)
        source.seek(0)
        p = subprocess.run(command, stdin=source, capture_output=True, env=env, timeout=15)
    assert (p.returncode, p.stdout, p.stderr) == (0, input_payload, b'')
# A worker that does not read stdin must exit even while the input pipe is open.
with subprocess.Popen([exe, 'true'], stdin=subprocess.PIPE,
                      stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env) as p:
    assert p.wait(timeout=5) == 0
# Terminal stdin must still produce EOF instead of waiting for user input.
input_master, input_slave = pty.openpty()
try:
    p = subprocess.run([exe, sys.executable, fixture, 'stdin'], stdin=input_slave,
                       capture_output=True, env=env, timeout=5)
    assert (p.returncode, p.stdout, p.stderr) == (0, b'', b'')
finally:
    os.close(input_master)
    os.close(input_slave)
for fd in ('1', '2'):
    assert worker('bytes', fd, stream='stdout' if fd == '1' else 'stderr') == payload
    assert run('--guess', sys.executable, fixture, 'bytes', fd, stream='stdout' if fd == '1' else 'stderr') == payload
assert run('--guess', sys.executable, fixture, 'exit', code=37) == b''
assert run('--guess', sys.executable, fixture, 'signal', code=143) == b''
assert run('true') == b''
volume = capture_output(sys.executable, fixture, 'volume')
# The child fills both pipes without any LF bytes. Check each destination
# independently, including byte order and output larger than the read buffer.
expected = b''.join(bytes(97 + int(digit, 16) for digit in format(i, '08x')) + b'q'
                    for i in range(3000))
assert volume.stdout == expected + b'x' * 20000
assert volume.stderr == expected.upper()
# A partial line must reach the output while the child is still running.
p = subprocess.Popen([exe, '--no-progress', sys.executable, fixture, 'partial'],
                     stdout=subprocess.PIPE, stderr=subprocess.PIPE)
try:
    ready, _, _ = select.select([p.stdout], [], [], 5)
    assert ready, 'partial output was buffered until EOF'
    partial = os.read(p.stdout.fileno(), 4096)
    assert partial == b'working\r' and p.poll() is None
    p.terminate()
    stdout, tail = p.communicate(timeout=5)
    assert stdout == b'' and tail == b'' and p.returncode == 143
finally:
    if p.poll() is None:
        p.kill()
        p.wait()
# A failed output device must not leave the child blocked on full pipes.
if sys.platform.startswith('linux'):
    for stream in ('stdout', 'stderr'):
        with open('/dev/full', 'wb') as sink:
            destinations = dict(stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            destinations[stream] = sink
            p = subprocess.run([exe, sys.executable, fixture, 'volume'],
                               **destinations, timeout=8)
        assert p.returncode == 1
    with open('/dev/full', 'wb') as sink:
        p = subprocess.run([exe, '--mock'], stderr=sink,
                           stdout=subprocess.PIPE, timeout=8)
    assert p.returncode == 1
assert worker('exit', code=37) == b''
assert worker('signal', code=143) == b''
for sig, mode in [(signal.SIGINT, 'stop'), (signal.SIGTERM, 'stop'), (signal.SIGINT, 'stubborn')]:
    p = subprocess.Popen([exe, sys.executable, fixture, mode], stderr=subprocess.PIPE, stdout=subprocess.PIPE)
    ready, _, _ = select.select([p.stdout], [], [], 5)
    assert ready
    pid = read_pid(p.stdout)
    start = time.monotonic()
    p.send_signal(sig)
    _, log = p.communicate(timeout=8)
    assert p.returncode == 128 + sig, (p.returncode, log)
    if mode == 'stubborn':
        assert time.monotonic() - start >= 1.8
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        pass
    else:
        raise AssertionError('child not reaped')
# Shutdown must also stop descendants when the leader exits on SIGTERM, or
# when the interrupt arrives after the leader exits during pipe draining.
for prefix in ([], ['--test']):
    for during_drain in (False, True):
        with tempfile.TemporaryDirectory() as directory:
            p = subprocess.Popen([exe, *prefix, sys.executable, fixture, 'shutdown-family'],
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                 env=dict(env, ZPG_TEST_SYNC=directory))
            descendant = None
            try:
                descendant = read_pid(p.stdout)
                if during_drain:
                    (pathlib.Path(directory) / 'parent-exit').touch()
                    parent = int((pathlib.Path(directory) / 'parent-pid').read_text())
                    deadline = time.monotonic() + 5
                    while True:
                        try:
                            os.kill(parent, 0)
                        except ProcessLookupError:
                            break
                        assert time.monotonic() < deadline, 'leader was not reaped'
                        time.sleep(.01)
                p.send_signal(signal.SIGINT)
                _, log = p.communicate(timeout=8)
                assert p.returncode == 130, (p.returncode, log)
                state = subprocess.run(['ps', '-o', 'stat=', '-p', str(descendant)],
                                       capture_output=True, text=True, timeout=5).stdout.strip()
                assert not state or state.startswith('Z'), (descendant, state, log)
            finally:
                if descendant is not None:
                    try:
                        os.kill(descendant, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                if p.poll() is None:
                    p.kill()
                    p.wait()

# Keep the descendant alive until the check ends. A fixed child lifetime can
# expire before the supervisor's drain deadline on a busy runner.
with tempfile.TemporaryDirectory() as directory:
    try:
        with tempfile.TemporaryFile() as stdout, tempfile.TemporaryFile() as stderr:
            p = subprocess.run([exe, '--name', 'worker', sys.executable, fixture,
                                'descendant'], stdout=stdout, stderr=stderr,
                               env=dict(env, ZPG_TEST_SYNC=directory), timeout=8)
            stdout.seek(0)
            stderr.seek(0)
            log = stderr.read()
            assert p.returncode == 0 and stdout.read() == b'parent done\n', (p.returncode, log)
            assert b'pipe drain timeout' in log, log
    finally:
        (pathlib.Path(directory) / 'release').touch()
        # Wait for the descendant to acknowledge release before removing it.
        deadline = time.monotonic() + 5
        while not (pathlib.Path(directory) / 'released').exists():
            assert time.monotonic() < deadline, 'descendant did not exit'
            time.sleep(.01)
mock_result = capture_output('zpg', '--mock')
assert b'mock stderr:' not in mock_result.stdout
assert b'mock stdout:' not in mock_result.stderr
log = mock_result.stdout + mock_result.stderr
assert log.count(b'mock stdout:') >= 20 and log.count(b'mock stderr:') >= 10
workers = re.findall(rb'mock worker (indexer|compiler|uploader) \(pid (\d+)\): started', log)
assert {name for name, _ in workers} == {b'indexer', b'compiler', b'uploader'}
assert len({pid for _, pid in workers}) == 3
for name in (b'indexer', b'compiler', b'uploader'):
    assert b'mock worker ' + name + b': complete' in log
assert max(log.index(b'mock worker ' + name + b' (pid') for name in
           (b'indexer', b'compiler', b'uploader')) < min(
               log.index(b'mock worker ' + name + b': complete') for name in
               (b'indexer', b'compiler', b'uploader'))
assert b'[zpg:' not in log and b'exited with code' not in log
assert b'mock stdout: complete' in log and b'mock stderr: complete' in log
assert b'\x1b' not in log
capture_output('--no-progress', 'zpg', '--mock')
# Input mode echoes complete lines and a final partial line, including lines
# that cross the read buffer. It must leave the fixed demo for empty stdin.
mock_input = b'first\n' + b'x' * 5000 + b'\nlast'
for prefix in ([], ['--no-progress']):
    start = time.monotonic()
    p = subprocess.run([exe, *prefix, '--mock'], input=mock_input,
                       capture_output=True, env=env, timeout=5)
    assert (p.returncode, p.stdout, p.stderr) == (0, mock_input, b'')
    assert time.monotonic() - start >= .3
with tempfile.TemporaryFile() as source:
    source.write(mock_input)
    source.seek(0)
    p = subprocess.run([exe, '--mock'], stdin=source,
                       capture_output=True, env=env, timeout=5)
assert (p.returncode, p.stdout, p.stderr) == (0, mock_input, b'')
p = subprocess.run([exe, 'zpg', '--mock'], input=mock_input,
                   capture_output=True, env=env, timeout=5)
assert (p.returncode, p.stdout, p.stderr) == (0, mock_input, b'')
# A long line must start streaming before newline or EOF, with bounded buffering.
# Writing exactly the buffer limit cannot block on output before all input is read.
long_line = b'x' * (64 * 1024)
p = subprocess.Popen([exe, '--mock'], stdin=subprocess.PIPE,
                     stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
try:
    p.stdin.write(long_line)
    p.stdin.flush()
    ready, _, _ = select.select([p.stdout], [], [], 5)
    assert ready, 'long mock input line was buffered until EOF'
    first = os.read(p.stdout.fileno(), 4096)
    assert first and first == long_line[:len(first)]
    p.stdin.close()
    p.stdin = None
    rest, errors = p.communicate(timeout=5)
    assert (p.returncode, first + rest, errors) == (0, long_line, b'')
finally:
    if p.poll() is None:
        p.kill()
        p.wait()
    if p.stdin is not None:
        p.stdin.close()
    p.stdout.close()
    p.stderr.close()
# Ctrl-C must stop a mock even when its input pipe remains open and idle.
for initial in (b'first\n', b'first\npartial'):
    p = subprocess.Popen([exe, '--mock'], stdin=subprocess.PIPE,
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
    try:
        p.stdin.write(initial)
        p.stdin.flush()
        ready, _, _ = select.select([p.stdout], [], [], 5)
        assert ready, 'mock did not echo its first input line'
        assert os.read(p.stdout.fileno(), 4096) == b'first\n'
        p.send_signal(signal.SIGINT)
        assert p.wait(timeout=3) == 130
    finally:
        if p.poll() is None:
            p.kill()
            p.wait()
        p.stdin.close()
        p.stdout.close()
        p.stderr.close()
# An interrupt must stop and reap all three worker processes.
p = subprocess.Popen([exe, '--mock'], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                     bufsize=0)
worker_pids = set()
worker_log = bytearray()
deadline = time.monotonic() + 8
while len(worker_pids) < 3 and time.monotonic() < deadline:
    ready, _, _ = select.select([p.stderr], [], [], .1)
    if ready:
        data = os.read(p.stderr.fileno(), 65536)
        if not data:
            break
        worker_log.extend(data)
        worker_pids.update(int(pid) for pid in re.findall(
            rb'mock worker (?:indexer|compiler|uploader) \(pid (\d+)\): started', worker_log))
assert len(worker_pids) == 3
p.send_signal(signal.SIGINT)
_, tail = p.communicate(timeout=8)
assert p.returncode == 130, (p.returncode, tail)
for pid in worker_pids:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        pass
    else:
        raise AssertionError(f'mock worker {pid} was not reaped')
# A PTY gives the renderer and the child's stderr a terminal.
master, slave = pty.openpty()
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 48, 100, 0, 0))
terminal_env = dict(env, TERM='xterm-256color')
terminal_env.pop('NO_COLOR', None)
terminal_env.pop('ZIG_PROGRESS', None)
p = subprocess.Popen([exe, 'zpg', '--mock'], stdout=subprocess.PIPE, stderr=slave, env=terminal_env)
os.close(slave)
log = bytearray()
deadline = time.monotonic() + MOCK_TIMEOUT
while time.monotonic() < deadline:
    ready, _, _ = select.select([master], [], [], .1)
    if ready:
        try:
            data = os.read(master, 65536)
        except OSError as e:
            if e.errno == errno.EIO:
                break
            raise
        if not data:
            break
        log.extend(data)
else:
    p.kill()
    raise AssertionError('terminal test timed out')
os.close(master)
assert p.wait(timeout=2) == 0
assert b'\x1b' in log, log
frames = [frame.split(b'\x1b[?2026l', 1)[0]
          for frame in log.split(b'\x1b[?2026h')]
# Short demo stages can finish between redraws. Exact labels and counts are
# checked below with fixtures that wait for the displayed frame.
assert any(b'\rmock [' in frame for frame in frames), frames
for name in (b'indexer', b'compiler', b'uploader'):
    assert b'mock worker ' + name + b': complete' in log, (name, log)
assert b'mock stdout:' in p.communicate(timeout=2)[0] and b'mock stderr:' in log
assert b'[zpg:' not in log and b'exited with code' not in log
master, slave = pty.openpty()
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 24, 100, 0, 0))
p = subprocess.Popen([exe, '--no-progress', 'zpg', '--mock'], stdout=slave, stderr=slave, env=terminal_env)
os.close(slave)
log = bytearray()
deadline = time.monotonic() + MOCK_TIMEOUT
try:
    while time.monotonic() < deadline:
        ready, _, _ = select.select([master], [], [], .1)
        if not ready:
            continue
        try:
            data = os.read(master, 65536)
        except OSError as error:
            if error.errno == errno.EIO:
                break
            raise
        if not data:
            break
        log.extend(data)
    else:
        raise AssertionError('no-progress terminal test timed out')
    assert p.wait(timeout=2) == 0, log
finally:
    os.close(master)
    if p.poll() is None:
        p.kill()
        p.wait()
assert b'\x1b[?2026h' not in log and b'\x1b[J' not in log, log
assert b'\x1b[32mmock stdout:' in log and b'\x1b[31mmock stderr:' in log, log
print('integration checks passed (including terminal progress)')


def progress_cleared(capture):
    return re.search(rb'\x1b\[\?2026h\x1b\[\d+B\r\x1b\[J'
                     rb'\x1b\[\d+A\x1b\[\d+G\x1b\[\?2026l$', capture) is not None


def terminal_capture(args, rows=12, cols=80, extra_env=None, resize=None,
                     stop_when=None, code=0, stdout_pattern=None, stdin=subprocess.DEVNULL,
                     timeout=15, checkpoints=None, on_output=None):
    if (checkpoints is None and render_probe in args and '--no-progress' not in args
            and (extra_env or {}).get('TERM') != 'dumb' and rows >= 5 and cols >= 24):
        frame = rb'\x1b\[\?2026h.*?\x1b\[\?2026l'
        # Hold each count until it is drawn. Wide bar displays must also show
        # two different spinner glyphs before the probe advances to completion.
        spinning = rb'unknown (\S+) 2 done.*unknown (?!\1 )\S+ 2 done'
        checkpoints = [(0, rb'3/4' if cols >= 80 else frame),
                       (1, spinning if cols >= 80 and 'tree' not in args else frame),
                       (2, rb'7/4' if cols >= 80 and not resize else frame)]
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', rows, cols, 0, 0))
    sync = FixtureSync(checkpoints)
    child_env = dict(terminal_env, **(extra_env or {}), **sync.environment())
    process = subprocess.Popen([exe, *args],
                               stdout=slave if stdout_pattern is None else subprocess.PIPE,
                               stdin=stdin, stderr=slave, env=child_env)
    os.close(slave)
    captured = bytearray()
    start = time.monotonic()
    resized = False
    stopped = False
    try:
        while time.monotonic() - start < timeout:
            ready, _, _ = select.select([master], [], [], .05)
            if not ready:
                continue
            try:
                data = os.read(master, 65536)
            except OSError as error:
                if error.errno == errno.EIO:
                    break
                raise
            if not data:
                break
            captured.extend(data)
            # Apply the action before releasing a held fixture stage.
            if stop_when and not stopped and re.search(stop_when, captured, re.S):
                process.send_signal(signal.SIGINT)
                stopped = True
            if resize and not resized and b'3/4' in captured:
                fcntl.ioctl(master, termios.TIOCSWINSZ,
                            struct.pack('HHHH', *resize, 0, 0))
                resized = True
            if on_output is not None:
                on_output(captured)
            if not stopped:
                sync.observe(captured)
        else:
            raise AssertionError(f'terminal test timed out after {timeout}s: {args!r}')
        stdout, _ = process.communicate(timeout=2)
        assert process.returncode == code, (args, process.returncode, captured[-8192:])
        if stdout_pattern is not None:
            assert re.fullmatch(stdout_pattern, stdout, re.S), stdout
        return bytes(captured)
    finally:
        os.close(master)
        if process.poll() is None:
            process.kill()
            process.wait()
        sync.close()


# Exercise stdin with active progress, including the macOS spawn path.
input_read, input_write = os.pipe()
try:
    os.write(input_write, b'pipe input marker\n')
finally:
    os.close(input_write)
try:
    capture = terminal_capture([sys.executable, fixture, 'stdin'], stdin=input_read)
    assert b'pipe input marker' in capture, capture
finally:
    os.close(input_read)
with tempfile.TemporaryFile() as source:
    source.write(b'file input marker\n')
    source.seek(0)
    capture = terminal_capture([sys.executable, fixture, 'stdin'], stdin=source)
    assert b'file input marker' in capture, capture
input_master, input_slave = pty.openpty()
try:
    terminal_capture([sys.executable, fixture, 'stdin'], stdin=input_slave)
finally:
    os.close(input_master)
    os.close(input_slave)

expected_logs = b'log line\n' * 12 + b'partial continued\n'
input_read, input_write = os.pipe()
try:
    with os.fdopen(input_write, 'wb', buffering=0) as input_writer:
        input_writer.write(b'alpha\nbeta\ngamma\n')

        def finish_mock_input(data):
            if b'input lines' in data:
                input_writer.close()

        capture = terminal_capture([exe, '--mock'], stdin=input_read,
                                   stdout_pattern=b'alpha\nbeta\ngamma\n',
                                   on_output=finish_mock_input)
        assert b'input lines' in capture, capture
finally:
    os.close(input_read)
if sys.platform.startswith('linux'):
    with tempfile.TemporaryDirectory() as directory:
        source = pathlib.Path(directory) / 'input.bin'
        source.write_bytes(b'x' * 1024)
        args = [sys.executable, fixture, 'file-io', str(source)]
        # The shell stays alive while its child reads, so this also checks
        # process-group discovery. Nested supervisors must forward estimates.
        for command in [args, ['sh', '-c', '"$@"; result=$?; exit "$result"', 'sh', *args],
                        [exe, '--guess', *args]]:
            capture = terminal_capture(['--guess', *command], cols=120,
                                       checkpoints=[(1, rb'25% 256/1024'),
                                                    (3, rb'75% 768/1024'),
                                                    ('closed', rb'I/O estimate \(unknown\)')])
            if command[0] != exe:
                assert b'\rzpg ' not in capture, capture
            assert b'I/O estimate (bytes): input.bin' in capture, capture
            assert b'25% 256/1024' in capture, capture
            assert b'75% 768/1024' in capture, capture
            known = (capture.find if command[0] == exe else capture.rfind)(b'75% 768/1024')
            # The outer estimate can become unknown while the nested one
            # still shows its last known count.
            assert b'I/O estimate (unknown)' in capture[known:], capture
            logs = output_without_overlay(capture)
            assert logs == b'copy step\r\n' * 2, logs
        capture = terminal_capture(['--guess', '--renderer', 'tree', *args],
                                   checkpoints=[(1, rb'I/O estimate \(bytes\): input.bin'),
                                                (3, rb'I/O estimate \(bytes\): input.bin'),
                                                ('closed', rb'I/O estimate \(unknown\)')])
        assert b'I/O estimate (bytes): input.bin' in capture, capture
        capture = terminal_capture(['--guess', '--no-progress', *args])
        assert capture == b'copy step\r\n' * 2, capture
        assert run('--guess', *args) == b'copy step\n' * 2
        capture = terminal_capture(['--guess', sys.executable, fixture,
                                    'output-only', str(source) + '.out'],
                                   checkpoints=[('unknown', rb'I/O estimate \(unknown\)')])
        assert b'I/O estimate (unknown)' in capture and b'100%' not in capture, capture
        capture = terminal_capture(['--guess', *args], stop_when=rb'25% 256/1024', code=130,
                                   checkpoints=[(1, None)])
        assert b'25% 256/1024' in capture and progress_cleared(capture), capture
        # Descriptors can close after a proc entry opens. Such races must not
        # add diagnostics or debug stack traces to the command's log.
        capture = terminal_capture(['--guess', sys.executable, fixture,
                                    'file-churn', str(source)])
        logs = output_without_overlay(capture)
        assert logs == b'churn complete\r\n', logs
        # File names must not inject terminal controls in either renderer.
        unusual = pathlib.Path(directory) / 'line\n\x1b[2Jé.bin'
        unusual.write_bytes(b'x' * 1024)
        for renderer in ('bars', 'tree'):
            capture = terminal_capture(['--guess', '--renderer', renderer,
                                        sys.executable, fixture, 'file-io', str(unusual)],
                                       cols=120, checkpoints=[(1, re.escape('line??[2Jé.bin'.encode())),
                                                              (3, re.escape('line??[2Jé.bin'.encode())),
                                                              ('closed', rb'I/O estimate \(unknown\)')])
            assert 'line??[2Jé.bin'.encode() in capture, capture
            assert b'\x1b[2J' not in capture, capture
        second = pathlib.Path(directory) / 'second.bin'
        second.write_bytes(b'x' * 2048)
        idle = pathlib.Path(directory) / 'idle.bin'
        with idle.open('wb') as sparse:
            sparse.truncate(1 << 30)
        for renderer, prefix in [('bars', []), ('tree', []), ('bars', [exe])]:
            first = (rb'bytes: input.bin.*25% 256/1024.*bytes: second.bin.*50% 1024/2048'
                     if renderer == 'bars' else
                     rb'\[256/1024\] bytes: input.bin.*\[1024/2048\] bytes: second.bin')
            advance = (rb'bytes: input.bin.*50% 512/1024.*bytes: second.bin.*75% 1536/2048'
                       if renderer == 'bars' else
                       rb'\[512/1024\] bytes: input.bin.*\[1536/2048\] bytes: second.bin')
            capture = terminal_capture(
                ['--renderer', renderer, *prefix, '--guess', sys.executable,
                 guess_fixture, 'parallel', str(source), str(second), str(idle)],
                cols=160, rows=16,
                checkpoints=[('open', rb'I/O estimate \(unknown\)'),
                             ('parallel', first), ('advance', advance),
                             ('single', rb'I/O estimate \(bytes\): second.bin'),
                             ('parallel-again', rb'2 active inputs(?=.*bytes: input.bin)(?=.*bytes: second.bin)'),
                             ('closed', rb'I/O estimate \(unknown\)')])
            frames = re.findall(rb'\x1b\[\?2026h(.*?)\x1b\[\?2026l', capture, re.S)
            parallel_frames = [frame for frame in frames if re.search(first, frame, re.S)]
            assert parallel_frames, capture
            for frame in parallel_frames:
                assert frame.count(b'bytes: input.bin') == 1, frame
                assert frame.count(b'bytes: second.bin') == 1, frame
                assert re.search('├─ .*bytes: input.bin'.encode(), frame), frame
                heading = next(line for line in frame.splitlines() if b'2 active inputs' in line)
                assert b'%' not in heading and b' done' not in heading, heading
            compact = [frame for frame in frames if b'I/O estimate (bytes): second.bin' in frame
                       and b'2 active inputs' not in frame]
            assert any(b'bytes: input.bin' not in frame and b'bytes: second.bin' not in frame
                       for frame in compact), capture
            assert b'idle.bin' not in capture, capture
            assert output_without_overlay(capture) == b'', capture
        many = [pathlib.Path(directory) / f'part-{index:02}.bin' for index in range(40)]
        for path in many:
            path.write_bytes(b'x' * 1024)
        capture = terminal_capture(
            ['--guess', sys.executable, guess_fixture, 'many', *map(str, many)],
            cols=120, rows=48, checkpoints=[('open', rb'I/O estimate \(unknown\)'),
                                           ('many', rb'40 active inputs; showing 32')])
        frames = re.findall(rb'\x1b\[\?2026h(.*?)\x1b\[\?2026l', capture, re.S)
        assert any(frame.count(b'bytes: part-') == 32 for frame in frames), capture
        for mode in ('backward', 'growing', 'eof'):
            source.write_bytes(b'x' * 1024)
            capture = terminal_capture(
                ['--guess', sys.executable, guess_fixture, mode, str(source)],
                cols=160, checkpoints=[('open', rb'I/O estimate \(unknown\)'),
                                       ('read', rb'25% 256/1024'),
                                       ('unknown', rb'I/O estimate \(unknown\)')])
            last_read = capture.rfind(b'25% 256/1024')
            assert b'I/O estimate (unknown)' in capture[last_read:], capture
        source.write_bytes(b'x' * 1024)
        capture = terminal_capture(
            ['--guess', sys.executable, guess_fixture, 'pread', str(source)],
            cols=160, checkpoints=[('open', rb'I/O estimate \(unknown\)'),
                                   ('activity', rb'Activity: read [1-9][0-9]*(\.[0-9])? (B|KiB|MiB)/s')])
        assert b'%' not in capture, capture
        capture = terminal_capture(
            ['--guess', sys.executable, guess_fixture, 'cpu'], cols=160,
            checkpoints=[('activity', rb'CPU active')])
        assert b'%' not in capture, capture
        # A kernel may disable SOCK_DIAG. The fallback must still work there;
        # exercise real TCP counters when the metadata interface is available.
        import socket
        try:
            with socket.socket(socket.AF_NETLINK, socket.SOCK_RAW, 4) as probe:
                probe.settimeout(1)
                request = struct.pack('=BBBBI', socket.AF_INET, socket.IPPROTO_TCP,
                                      2, 0, 0xffffffff) + bytes(48)
                probe.send(struct.pack('=IHHII', 72, 20, 0x301, 1, 0) + request)
                reply = probe.recv(32768)
                tcp_supported = len(reply) >= 16 and struct.unpack_from('=H', reply, 4)[0] != 2
        except OSError:
            tcp_supported = False
        if tcp_supported:
            capture = terminal_capture(
                ['--guess', sys.executable, guess_fixture, 'tcp'], cols=160,
                checkpoints=[('connected', rb'TCP observed(?: \(partial\))?: 0 B in, 0 B out'),
                             ('transferred', rb'TCP observed(?: \(partial\))?: 32 KiB in, 32 KiB out')])
            assert b'%' not in capture, capture
            assert output_without_overlay(capture) == b'', capture
        # Sparse files exercise >4 GiB counts without substantial disk use.
        with source.open('wb') as sparse:
            sparse.truncate(1 << 34)
        capture = terminal_capture(['--guess', sys.executable, fixture,
                                    'file-seek', str(source)], cols=120,
                                   checkpoints=[(1, rb'25% 4194304/16777216'),
                                                (3, rb'75% 12582912/16777216'),
                                                ('closed', rb'I/O estimate \(unknown\)')])
        assert b'I/O estimate (KiB): input.bin' in capture, capture
        assert b'25% 4194304/16777216' in capture, capture
        assert b'75% 12582912/16777216' in capture, capture

# Native reports remain usable when the separate I/O estimate is enabled.
capture = terminal_capture(['--guess', sys.executable, fixture, 'native-report'],
                           checkpoints=[('native', rb'native \[###---------\] 25% 1/4')])
assert b'native [###---------] 25% 1/4' in capture, capture
# Every spawned child needs the descriptor and its environment variable,
# including a child of a nested supervisor. Check this without frame timing.
for prefix in [[], [exe]]:
    capture = terminal_capture([*prefix, sys.executable, fixture, 'progress-env'])
    assert b'progress pipe: open\r\n' in capture, capture
capture = terminal_capture(['--no-progress', sys.executable, fixture, 'progress-env'])
assert capture == b'progress pipe: absent\r\n', capture
# Exercise spawn failure and exit status while a progress pipe is active.
terminal_capture(['zpg-command-that-does-not-exist'], code=1)
terminal_capture([sys.executable, fixture, 'exit'], code=37)
terminal_capture([sys.executable, fixture, 'signal'], code=143)
# A descendant can also hold PTY slaves open. The capture timeout must still
# stop zpg, without waiting for those descendants to close their descriptors.
with tempfile.TemporaryDirectory() as directory:
    try:
        capture = terminal_capture(['--no-progress', sys.executable, fixture, 'descendant'],
                                   extra_env={'ZPG_TEST_SYNC': directory}, timeout=8)
        assert b'parent done\r\n' in capture and b'pipe drain timeout' in capture, capture
    finally:
        (pathlib.Path(directory) / 'release').touch()
        deadline = time.monotonic() + 5
        while not (pathlib.Path(directory) / 'released').exists():
            assert time.monotonic() < deadline, 'descendant did not exit'
            time.sleep(.01)
# The demo can exit before its final report is drawn. Check completion and
# drawing here; the report fixture below keeps exact counts visible before exit.
demo_capture = terminal_capture(['--name', 'shell demo', 'sh', report_demo])
assert b'\x1b[?2026h' in demo_capture, demo_capture
assert b'shell demo: complete\r\n' in demo_capture, demo_capture
for worker_name in (b'indexer', b'compiler', b'uploader'):
    assert worker_name + b': finish complete' in demo_capture, (worker_name, demo_capture)
# Reports must remain visible after each short-lived reporter exits, and
# reach either renderer through a nested supervisor.
report_command = [sys.executable, fixture, 'reports']
report_steps = [(1, rb'25% 1/4'), (3, rb'compile .*75% 3/4'), (4, rb'done .*100% 4/4')]
for prefix in [[], [exe]]:
    report_capture = terminal_capture([*prefix, '--name', 'script', *report_command],
                                      checkpoints=report_steps)
    assert b'script [###---------] 25% 1/4' in report_capture, report_capture
    assert b'compile [#########---] 75% 3/4' in report_capture, report_capture
    assert b'done [############] 100% 4/4' in report_capture, report_capture
report_capture = terminal_capture(['--renderer', 'tree', *report_command],
                                  checkpoints=[(1, rb'1/4'), (3, rb'compile'), (4, rb'done')])
assert b'compile' in report_capture and b'done' in report_capture, report_capture
report_capture = terminal_capture(['--no-progress', *report_command])
assert report_capture == b'', report_capture
assert run('--renderer', 'bars', render_probe) == expected_logs
capture = terminal_capture([render_probe], rows=8)
frames = re.findall(rb'\x1b\[\?2026h(.*?)\x1b\[\?2026l', capture, re.S)
assert frames
assert all(b'\rzpg ' not in frame for frame in frames), frames
assert any(b'[#########---] 75% 3/4' in frame for frame in frames)
assert any(b'[############] 100% 7/4' in frame for frame in frames)
spinner_frames = set(re.findall(rb'unknown ([|/\\-]) 2 done', capture))
assert len(spinner_frames) > 1, spinner_frames
assert b'unsafe?[2J label?' in capture
assert b'\x1b[2J' not in capture and '\u202e'.encode() not in capture
# Removing only overlay operations must leave the original log bytes.
logs = output_without_overlay(capture)
assert logs == expected_logs.replace(b'\n', b'\r\n')
assert progress_cleared(capture), 'the final progress tree was not cleared'

# Custom Unicode styles must preserve log bytes and render complete codepoints.
custom_args = ['--bar-style', 'block', '--spinner-style', '⠋⠙']
assert run(*custom_args, render_probe) == expected_logs
custom_capture = terminal_capture([*custom_args, render_probe])
assert ('█' * 9 + '    75% 3/4').encode() in custom_capture
assert ('█' * 12 + ' 100% 7/4').encode() in custom_capture
assert 'unknown ⠋ 2 done'.encode() in custom_capture
assert 'unknown ⠙ 2 done'.encode() in custom_capture
custom_logs = output_without_overlay(custom_capture)
assert custom_logs == expected_logs.replace(b'\n', b'\r\n')
custom_capture.decode('utf-8')
custom_capture = terminal_capture(['--bar-style', '(▓░)', '--spinner-style', 'ab', render_probe])
assert ('(' + '▓' * 9 + '░' * 3 + ') 75% 3/4').encode() in custom_capture
assert b'unknown a 2 done' in custom_capture and b'unknown b 2 done' in custom_capture
custom_capture = terminal_capture([*custom_args, render_probe], cols=24)
custom_frames = re.findall(rb'\x1b\[\d+A\x1b\[\d+B\r(.*?)\x1b\[\d+A\x1b\[\d+G', custom_capture, re.S)
assert custom_frames
for frame in custom_frames:
    assert all(len(line) < 24 for line in frame.decode().replace('\r', '').split('\n'))

# Fira Code defaults must reach the terminal, with independent CLI overrides.
fira_env = {'UNICODE_PROGRESS_BAR': 'true'}
fira_args = ['--bar-style', 'fira', '--spinner-style', 'fira']
fira_bar = ('\uee03' + '\uee04' * 8 + '\uee01' * 2 + '\uee02' + ' 75% 3/4').encode()
fira_full = ('\uee03' + '\uee04' * 10 + '\uee05' + ' 100% 7/4').encode()
assert run(*fira_args, render_probe) == expected_logs
for args, overrides in [([render_probe], fira_env),
                        ([*fira_args, render_probe], {'UNICODE_PROGRESS_BAR': 'false'})]:
    fira_capture = terminal_capture(args, extra_env=overrides)
    assert fira_bar in fira_capture and fira_full in fira_capture
    fira_frames = set(re.findall('unknown ([\uee06-\uee0b]) 2 done', fira_capture.decode()))
    assert len(fira_frames) > 1, fira_frames
    fira_logs = output_without_overlay(fira_capture)
    assert fira_logs == expected_logs.replace(b'\n', b'\r\n')
fira_capture = terminal_capture(['--bar-style', 'ascii', render_probe], extra_env=fira_env)
assert b'[#########---] 75% 3/4' in fira_capture
assert re.search('unknown [\uee06-\uee0b] 2 done', fira_capture.decode())
fira_capture = terminal_capture(['--spinner-style', 'ascii', render_probe], extra_env=fira_env)
assert fira_bar in fira_capture
assert re.search(rb'unknown [|/\\-] 2 done', fira_capture)
fira_capture = terminal_capture(['--bar-style', 'ascii', '--spinner-style', 'ascii', render_probe],
                                extra_env=fira_env)
assert b'[#########---] 75% 3/4' in fira_capture
assert not re.search('[\uee00-\uee0b]', fira_capture.decode())
fira_capture = terminal_capture([render_probe], extra_env={'UNICODE_PROGRESS_BAR': 'false'})
assert b'[#########---] 75% 3/4' in fira_capture

# The same independent screen model is used by the focused terminal suite.
def replay_terminal(data, rows, cols, snapshots=None):
    terminal = Terminal(rows, cols)
    feed_output(terminal, data)
    if snapshots is not None:
        snapshots.extend(terminal.snapshots)
    return terminal.lines()


visible_logs = [line for line in replay_terminal(capture, 8, 80) if line]
assert visible_logs == expected_logs.decode().splitlines(), visible_logs
capture = terminal_capture([render_probe], stop_when=rb'75% 3/4', code=130)
assert b'75% 3/4' in capture and progress_cleared(capture)

# A resize must constrain subsequent frames without a signal handler.
capture = terminal_capture([render_probe], rows=12, cols=80, resize=(5, 24))
frames = re.findall(rb'\x1b\[\d+A\x1b\[\d+B\r(.*?)\x1b\[\d+A\x1b\[\d+G', capture, re.S)
assert frames
# Each fixture glyph uses one column, including the Unicode tree branches.
last_lines = frames[-1].decode().replace('\r', '').split('\n')
assert len(last_lines) <= 3 and all(len(line) < 24 for line in last_lines), last_lines
for size in [(3, 8), (1, 1)]:
    terminal_capture([render_probe], rows=size[0], cols=size[1])

# Nesting still sends progress to the outer process, which owns the display.
capture = terminal_capture([exe, render_probe])
assert b'[#########---] 75% 3/4' in capture
capture = terminal_capture([*custom_args, exe, '--bar-style', 'ascii', render_probe])
assert ('█' * 9 + '    75% 3/4').encode() in capture
assert b'[#########---]' not in capture
capture = terminal_capture([*custom_args, exe, '--mock'], stop_when='█'.encode(), code=130,
                           stdout_pattern=rb'(mock stdout: work in progress\n|mock worker: processing item\n)+')
assert '█'.encode() in capture
capture = terminal_capture(['--renderer', 'tree', render_probe])
assert b'\x1b' in capture and b'render probe' in capture
assert b'[#########---]' not in capture
tree_frames = re.findall(rb'\x1b\[\?2026h(.*?)\x1b\[\?2026l', capture, re.S)
assert any(b'\rrender-probe' in frame or b'\r[3/4] render probe' in frame
           for frame in tree_frames), tree_frames
assert all(b'zpg' not in frame for frame in tree_frames), tree_frames
capture = terminal_capture([render_probe], extra_env={'NO_COLOR': '1'})
assert b'[#########---] 75% 3/4' in capture
# An independent worker can now render its own output after detecting a TTY.
# --no-progress disables zpg's display; it must not filter the worker's escapes.
for args in [['--no-progress', render_probe],
             ['--no-progress', *custom_args, render_probe]]:
    capture = terminal_capture(args)
    assert b'[3/4] render probe' in capture and b'render probe [' not in capture, capture
    assert b'unsafe\x1b[2J label' in capture, capture
capture = terminal_capture([render_probe], extra_env={'TERM': 'dumb'})
assert b'\x1b' not in capture and capture == expected_logs.replace(b'\n', b'\r\n'), capture
# Replay both renderers with child row updates, including split sequences and
# saved cursors. Intermediate frames use a worker handshake in terminal_output.py.
control_expected = ['log'] * 10 + [
    'bar 100%', 'footer done', 'items 2/2', 'saved: restored',
    'backspace       end', 'wide: 界 complete café e\u0301',
]
for renderer in ('bars', 'tree'):
    for prefix in ([], [exe]):
        for fd in ('1', '2'):
            control_capture = terminal_capture(['--renderer', renderer, *prefix,
                                                 sys.executable, fixture, 'controls', fd], rows=8)
            visible = [line for line in replay_terminal(control_capture, 8, 80) if line]
            # A saved cursor on the last row can point at a different line
            # after scrolling. Fewer progress rows change when that scroll occurs.
            scrolled = control_expected[:13] + ['saved:', '       restored'] + control_expected[14:]
            assert visible in (control_expected, scrolled), (renderer, prefix, fd, visible)
            # After removing zpg's drawing, all child control bytes must remain.
            raw = output_without_overlay(control_capture)
            direct = run('--no-progress', sys.executable, fixture, 'controls', fd,
                         stream='stdout' if fd == '1' else 'stderr')
            assert raw == direct.replace(b'\n', b'\r\n'), (raw, direct)

print('custom renderer checks passed (including resize and partial log lines)')


# Give stdout and stderr different terminals so the tests can identify exactly
# which descriptor receives progress. Non-terminal streams go to real files.
def capture_destinations(args, stdout_tty, stderr_tty, stdin=subprocess.DEVNULL,
                         extra_env=None, timeout=15, convert=False, checkpoints=None, checkpoint_stream='stderr'):
    sync = FixtureSync(checkpoints)
    terminals = {}
    files = {}
    destinations = {}
    captured = {name: bytearray() for name in ('stdout', 'stderr')}
    process = None
    try:
        for name, is_tty in [('stdout', stdout_tty), ('stderr', stderr_tty)]:
            if is_tty:
                master, slave = pty.openpty()
                terminals[name] = (master, slave)
                fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 12, 80, 0, 0))
                attributes = termios.tcgetattr(slave)
                if convert:
                    attributes[1] |= termios.OPOST | termios.ONLCR
                else:
                    attributes[1] &= ~termios.OPOST
                termios.tcsetattr(slave, termios.TCSANOW, attributes)
                destinations[name] = slave
            else:
                files[name] = tempfile.TemporaryFile()
                destinations[name] = files[name]
        process = subprocess.Popen([exe, *args], stdin=stdin, **destinations,
                                   env=dict(terminal_env, **(extra_env or {}), **sync.environment()))
        for _, slave in terminals.values():
            os.close(slave)
        active = {master: name for name, (master, _) in terminals.items()}
        deadline = time.monotonic() + timeout
        while active:
            assert time.monotonic() < deadline, (
                f'stream selection test timed out after {timeout}s: {args!r}')
            ready, _, _ = select.select(list(active), [], [], .1)
            for master in ready:
                try:
                    data = os.read(master, 65536)
                except OSError as error:
                    if error.errno != errno.EIO:
                        raise
                    data = b''
                if data:
                    captured[active[master]].extend(data)
                    sync.observe(captured[checkpoint_stream or 'stderr'])
                else:
                    del active[master]
        returncode = process.wait(timeout=max(0, deadline - time.monotonic()))
        assert returncode == 0, (args, returncode, captured)
        for name, file in files.items():
            file.seek(0)
            captured[name].extend(file.read())
        return {name: bytes(data) for name, data in captured.items()}
    finally:
        if process is not None and process.poll() is None:
            process.kill()
            process.wait()
        for master, slave in terminals.values():
            os.close(master)
            if process is None:
                os.close(slave)
        for file in files.values():
            file.close()
        sync.close()


# The mock draws independently on stdout and stderr. A nested supervisor can
# forward those streams in a different order, even between a write and its LF.
# Use separate terminals so each animation has its own cursor and byte order.
for prefix in ([], [exe]):
    captures = capture_destinations([*prefix, '--mock'], True, True,
                                    timeout=MOCK_TIMEOUT, convert=True)
    if not prefix:
        assert all(b'\x1b[?2026h' not in data for data in captures.values()), captures
    for name, expected_lines in [
            ('stdout', ['mock carriage return: [####] 100%', 'mock stdout: complete']),
            ('stderr', ['mock footer: complete', 'mock footer items: 2/2',
                        'mock stderr: complete'])]:
        visible = [line for line in replay_terminal(captures[name], 12, 80) if line]
        assert visible[-len(expected_lines):] == expected_lines, (prefix, name, visible[-10:])
        assert not any('mock footer: waiting' in line or 'mock footer: running' in line
                       for line in visible), (prefix, name, visible[-10:])
print('mock terminal animations passed (including nested capture)')


# The fixed mock demo colors each stream only when that stream is a terminal.
# Worker logs follow the same rule through the capture PTYs.
for stdout_tty, stderr_tty in [(False, False), (False, True),
                              (True, False), (True, True)]:
    captures = capture_destinations(['--no-progress', '--mock'], stdout_tty, stderr_tty,
                                    timeout=MOCK_TIMEOUT)
    for name, terminal, color in [('stdout', stdout_tty, b'\x1b[32m'),
                                  ('stderr', stderr_tty, b'\x1b[31m')]:
        data = captures[name]
        assert b'mock worker' in data and b'mock ' + name.encode() + b':' in data, data
        if terminal:
            assert all(line.startswith(color) and line.endswith(b'\x1b[0m\n')
                       for line in data.splitlines(keepends=True)
                       if b'mock worker' in line or b'mock ' + name.encode() + b':' in line), (name, data)
            assert (b'mock carriage return:' if name == 'stdout' else b'mock footer:') in data
            assert b'\x1b[?2026h' not in data, data
        else:
            assert b'\x1b' not in data, (name, data)

# Input echo must keep its bytes even when both destinations are terminals.
read_fd, write_fd = os.pipe()
try:
    os.write(write_fd, b'raw input\n')
finally:
    os.close(write_fd)
try:
    captures = capture_destinations(['--no-progress', '--mock'], True, True, stdin=read_fd)
finally:
    os.close(read_fd)
assert captures == dict(stdout=b'raw input\n', stderr=b''), captures
print('mock output color and input echo checks passed')

# TTY status follows each destination separately, including nested commands.
# Progress settings and TERM must not change the stream's TTY status.
for stdout_tty, stderr_tty in [(False, False), (False, True),
                              (True, False), (True, True)]:
    for prefix, overrides in [(['--no-progress'], {}),
                              (['--no-progress', exe], {}),
                              (['--no-progress'], {'TERM': 'dumb'}),
                              (['--progress-stream', 'stdout'], {}),
                              (['--progress-stream', 'stderr'], {})]:
        captures = capture_destinations([*prefix, sys.executable, fixture, 'tty'],
                                        stdout_tty, stderr_tty, extra_env=overrides)
        for fd, name, terminal in [(1, 'stdout', stdout_tty), (2, 'stderr', stderr_tty)]:
            expected_tty = f'fd={fd} tty={terminal}'.encode()
            if terminal:
                expected_tty = b'\x1b[32m' + expected_tty + b' size=80x12\x1b[0m'
            assert expected_tty + b'\n' in captures[name], captures

    # Include all byte values, ANSI escapes, CR, LF, and data larger than a PTY
    # buffer. Neither the capture PTY nor the outer test terminal may alter it.
    for fd, name in [('1', 'stdout'), ('2', 'stderr')]:
        captures = capture_destinations(['--no-progress', sys.executable, fixture,
                                         'bytes', fd], stdout_tty, stderr_tty)
        assert captures[name] == payload, (stdout_tty, stderr_tty, name, captures)
        assert captures['stderr' if name == 'stdout' else 'stdout'] == b'', captures
    captures = capture_destinations(['--no-progress', sys.executable, fixture, 'volume'],
                                    stdout_tty, stderr_tty)
    assert captures == dict(stdout=expected + b'x' * 20000, stderr=expected.upper()), captures
    # Empty PTYs must close without an I/O error or a drain timeout.
    assert capture_destinations(['--no-progress', 'true'], stdout_tty, stderr_tty) == dict(stdout=b'', stderr=b'')
print('worker TTY status, color, and byte preservation checks passed')

captures = capture_destinations(['--no-progress', exe, sys.executable, fixture, 'volume'],
                                True, True)
assert captures == dict(stdout=expected + b'x' * 20000, stderr=expected.upper()), captures

stream_command = [sys.executable, fixture, 'streams']
for renderer in ('bars', 'tree'):
    for stdout_tty, stderr_tty, choice, selected in [
            (False, False, 'auto', None),
            (False, True, 'auto', 'stderr'),
            (True, False, 'auto', 'stdout'),
            (True, True, 'auto', 'stderr'),
            (True, True, 'stdout', 'stdout'),
            (True, True, 'stderr', 'stderr'),
            (False, True, 'stdout', None),
            (True, False, 'stderr', None)]:
        args = ['--renderer', renderer, '--progress-stream', choice, *stream_command]
        captures = capture_destinations(
            args, stdout_tty, stderr_tty,
            checkpoints=[('progress', rb'stream-progress')] if selected else None,
            checkpoint_stream=selected)
        for name, data in captures.items():
            marker = (name + ' marker\n').encode()
            if name == selected:
                assert b'\x1b' in data and b'stream-progress' in data, (args, name, data)
                assert marker in data and (name + ' tail\n').encode() in data, (args, name, data)
                assert (('stderr' if name == 'stdout' else 'stdout') + ' marker').encode() not in data
            else:
                assert data == marker + (name + ' tail\n').encode(), (args, name, data)
    for options, overrides in [(['--no-progress'], {}), ([], {'TERM': 'dumb'})]:
        captures = capture_destinations(['--renderer', renderer, *options, *stream_command],
                                        True, True, extra_env=overrides)
        assert captures == dict(stdout=b'stdout marker\nstdout tail\n', stderr=b'stderr marker\nstderr tail\n'), captures
    # The outer process selects the terminal, even with conflicting inner flags.
    captures = capture_destinations(['--renderer', renderer, '--progress-stream', 'stdout',
                                     exe, '--progress-stream', 'stderr', *stream_command],
                                    True, True, checkpoints=[('progress', rb'stream-progress')],
                                    checkpoint_stream='stdout')
    assert b'stream-progress' in captures['stdout']
    assert captures['stderr'] == b'stderr marker\nstderr tail\n'
    # A pipe on stdin and a file on stdout must preserve all bytes while stderr
    # continues to display progress, including with nested supervisors.
    for prefix in ([], [exe]):
        read_fd, write_fd = os.pipe()
        input_bytes = bytes(range(256)) * 4
        try:
            os.write(write_fd, input_bytes)
        finally:
            os.close(write_fd)
        try:
            # Each nested collector has a startup delay. Keep the worker alive
            # until its progress reaches the terminal, even on a slow runner.
            captures = capture_destinations(
                ['--renderer', renderer, *prefix, sys.executable, fixture, 'stdin-progress'],
                False, True, stdin=read_fd,
                checkpoints=[('progress', rb'input-progress')])
        finally:
            os.close(read_fd)
        assert captures['stdout'] == input_bytes, (renderer, prefix, captures)
        assert b'input-progress' in captures['stderr'] and b'\x1b' in captures['stderr'], (
            renderer, prefix, captures)
print('separate streams and progress terminal selection checks passed')

# The same terminal can be reached by both descriptors. Verify that stdout
# progress also preserves partial log lines when the overlay causes scrolling.
capture = terminal_capture(['--progress-stream', 'stdout', render_probe], rows=8)
visible_logs = [line for line in replay_terminal(capture, 8, 80) if line]
assert visible_logs == expected_logs.decode().splitlines(), visible_logs

# Test mode reads raw packets even with redirected output and fast child exits.
for kind, code in [('valid', 0), ('maximum', 0), ('invalid', 1), ('truncated', 1),
                   ('reserved-254', 1), ('reserved-255', 1), ('reserved-total', 1),
                   ('bad-root', 1), ('orphan', 1), ('invalid-exit', 37)]:
    with tempfile.TemporaryDirectory() as directory:
        path = pathlib.Path(directory) / 'progress.log'
        p = capture_output('--test', '--test-output', str(path),
                           sys.executable, fixture, 'test-progress', kind, code=code)
        assert p.stdout == b'child stdout\x00', p.stdout
        assert p.stderr == b'child stderr\n', p.stderr
        log = path.read_bytes()
        assert b'progress pipe opened' in log, log
        if code == 0:
            if kind == 'valid':
                assert b'snapshot=2 nodes=2 unchanged' in log, log
                assert b'completed=4 total=4' in log, log
                assert b'nodes=0 changed' in log, log
            else:
                assert b'nodes=253 changed' in log, log
                assert b'node=252 parent=251 completed=4294967295 total=4294967294' in log, log
            assert b'\x1b' not in log, log
            assert b'protocol=no errors detected' in log, log
        else:
            assert b'error:' in log and b'protocol=invalid' in log, log
p = capture_output('--test', sys.executable, fixture, 'exit', code=37)
assert b'no progress received' in p.stderr, p.stderr
assert b'process result=' in p.stderr, p.stderr
p = capture_output('--test', 'sh', '-c', 'zpg --report 3 4 --name work')
assert b'completed=3 total=4 name="work"' in p.stderr, p.stderr
# Labels in diagnostic logs cannot insert terminal or Unicode direction controls.
unsafe_label = 'label\x1b[2J\n\u009b\u202e\u2066'
p = capture_output('--test', exe, '--report', '1', '2', '--name', unsafe_label)
assert b'label\\x1b[2J\\n\\xc2\\x9b\\xe2\\x80\\xae\\xe2\\x81\\xa6' in p.stderr, p.stderr
assert b'\x1b' not in p.stderr and '\u202e'.encode() not in p.stderr, p.stderr
# Raw-pipe spawning must preserve PATH search, launch errors, and process groups.
with tempfile.TemporaryDirectory() as directory:
    root = pathlib.Path(directory)
    denied, allowed = root / 'denied', root / 'allowed'
    denied.mkdir()
    allowed.mkdir()
    (denied / 'lookup').write_text('not executable\n')
    command = allowed / 'lookup'
    command.write_text('#!/bin/sh\nprintf "%s\\n" "$1"\n')
    command.chmod(0o755)
    for search in [f'{denied}:{allowed}', f'{command}/not-a-directory:{allowed}', '']:
        p = subprocess.run([exe, '--test', 'lookup', 'argument value'],
                           cwd=allowed, env=dict(env, PATH=search),
                           capture_output=True, timeout=5)
        assert (p.returncode, p.stdout) == (0, b'argument value\n'), p
    for search, error in [(str(denied), b'AccessDenied'),
                          (str(root / 'missing'), b'FileNotFound')]:
        p = subprocess.run([exe, '--test', 'lookup'], env=dict(env, PATH=search),
                           capture_output=True, timeout=5)
        assert p.returncode == 1 and error in p.stderr, p
    # Text without a shebang must fail to launch, including through PATH.
    # A shell fallback would run this valid shell command and exit with 42.
    command.write_text('exit 42\n')
    for name in [str(command), 'lookup']:
        p = subprocess.run([exe, '--test', name], env=dict(env, PATH=str(allowed)),
                           capture_output=True, timeout=5)
        assert p.returncode == 1 and b'InvalidExe' in p.stderr, p
        assert b'process result=' not in p.stderr, p.stderr
    p = capture_output('--test', str(command / 'child'), code=1)
    assert b'NotDir' in p.stderr, p.stderr
p = capture_output('--test', 'zpg-command-that-does-not-exist', code=1)
assert b'FileNotFound' in p.stderr, p.stderr
state = ('import os, sys; '
         'assert os.getpid() == os.getpgrp(); '
         'assert os.get_inheritable(int(os.environ["ZIG_PROGRESS"])); '
         'sys.stdout.buffer.write(sys.stdin.buffer.read())')
p = subprocess.run([exe, '--test', sys.executable, '-c', state],
                   input=b'input\x00bytes\n', capture_output=True, env=env, timeout=5)
assert (p.returncode, p.stdout) == (0, b'input\x00bytes\n'), p
p = subprocess.Popen([exe, '--test', sys.executable, fixture, 'stop'],
                     stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
try:
    assert read_pid(p.stdout) > 0
    p.send_signal(signal.SIGTERM)
    _, log = p.communicate(timeout=5)
    assert p.returncode == 143, (p.returncode, log)
finally:
    if p.poll() is None:
        p.kill()
        p.wait()
for args in [('--test-output', 'log', 'true'), ('--test', '--test-output'),
             ('--test', '--mock'), ('--test', '--no-progress', 'true'),
             ('--test', '--guess', 'true'), ('--test', '--report', '0', '1')]:
    capture_output(*args, code=2)

# Tasks share output and progress, but have independent process groups.
tasks_fixture = str(pathlib.Path(__file__).parent / 'fixtures' / 'tasks_worker.py')
with tempfile.TemporaryDirectory() as directory:
    root = pathlib.Path(directory)
    tasks_path = root / 'tasks.json'

    def task_file(tasks, **options):
        tasks_path.write_text(json.dumps(dict(tasks=tasks, **options)))
        return str(tasks_path)

    def task_worker(mode, fixture_name, *args, **options):
        return dict(command=[sys.executable, tasks_fixture, mode, directory, fixture_name, *args],
                    **options)

    # Both workers must start before either one can finish. Nonzero exits do
    # not cancel other tasks by default; all completion markers must exist.
    task_file([task_worker('barrier', 'alpha', 'beta', '7'),
               task_worker('barrier', 'beta', 'alpha', '9', guess=True)])
    p = capture_output('--tasks', str(tasks_path), code=7)
    assert sorted(p.stdout.splitlines()) == [b'alpha stdout', b'beta stdout'], p
    assert sorted(p.stderr.splitlines()) == [b'alpha stderr', b'beta stderr'], p
    assert all((root / (name + '.done')).exists() for name in ('alpha', 'beta'))

    # Each stream receives a binary payload larger than the queue's chunks.
    task_file([dict(command=[sys.executable, fixture, 'bytes', str(fd)]) for fd in (1, 2)])
    p = capture_output('--tasks', str(tasks_path))
    assert p.stdout == payload and p.stderr == payload
    p = capture_output('--no-progress', '--tasks', str(tasks_path))
    assert p.stdout == payload and p.stderr == payload

    task_file([dict(command=[sys.executable, '-c',
                            'import json,sys; print(json.dumps(sys.argv[1:]))',
                            '{{.1}}', 'prefix/{{.2}}', '{{.3}}', '{{.1}}'])])
    p = capture_output('--tasks', str(tasks_path), '--flag with spaces;$HOME', '{{.1}}', '')
    assert json.loads(p.stdout) == ['--flag with spaces;$HOME', 'prefix/{{.1}}', '',
                                   '--flag with spaces;$HOME']
    assert p.stderr == b''

    # Invalid later tasks must not allow earlier commands to run.
    marker = root / 'must-not-start'
    valid_task = dict(command=[sys.executable, '-c',
                              'from pathlib import Path; Path(__import__("sys").argv[1]).touch()',
                              str(marker)])
    for invalid in [dict(command=[]), dict(command=['']), dict(command=['true', '{{.2}}']),
                    dict(command=['true', '{{.0}}']), dict(command=['true'], guess='yes'),
                    dict(command=['true'], typo=True), dict(command=['a\x00b'])]:
        task_file([valid_task, invalid])
        capture_output('--tasks', str(tasks_path), code=2)
        assert not marker.exists()
    for invalid in ['{', '[]', '{"tasks":[]}', '{"tasks":[{"command":"true"}]}']:
        tasks_path.write_text(invalid)
        capture_output('--tasks', str(tasks_path), code=2)
    capture_output('--tasks', str(root / 'missing.json'), code=2)

    # Expansion limits apply to the whole file, before any task starts.
    # Each argument and task is small; their combined expanded size is not.
    expanded_task = dict(command=['true', *(['{{.1}}'] * 65)])
    task_file([valid_task, expanded_task, expanded_task])
    p = capture_output('--tasks', str(tasks_path), 'x' * 65536, code=2)
    assert b'TaskArgumentsTooLarge' in p.stderr and not marker.exists(), p.stderr
    task_file([valid_task, dict(command=['true', '{{.1}}' * 129])])
    p = capture_output('--tasks', str(tasks_path), 'x' * 65536, code=2)
    assert b'TaskArgumentsTooLarge' in p.stderr and not marker.exists(), p.stderr

    # Error paths quote untrusted file names, task labels, and executable names.
    hostile_name = 'missing\x1b[2J\n\u009b\u202e'
    escaped_name = b'missing\\x1b[2J\\n\\xc2\\x9b\\xe2\\x80\\xae'
    p = capture_output('--tasks', str(root / hostile_name), code=2)
    assert escaped_name in p.stderr and p.stderr.count(b'\n') == 1, p.stderr
    for task in [dict(name=hostile_name, command=['zpg-command-that-does-not-exist']),
                 dict(command=[str(root / hostile_name)])]:
        task_file([task])
        p = capture_output('--tasks', str(tasks_path), code=1)
        assert escaped_name in p.stderr and b'\x1b' not in p.stderr, p.stderr
        assert p.stderr.count(b'\n') == 2, p.stderr

    # Signals during launch must prevent later tasks from starting. The first
    # shell sends the signal while zpg is still creating the remaining jobs.
    for sig in ('INT', 'TERM'):
        task_file([dict(command=['sh', '-c', f'kill -{sig} "$PPID"'])] +
                  [dict(command=['true']) for _ in range(30)] + [valid_task])
        p = capture_output('--tasks', str(tasks_path), code=130 if sig == 'INT' else 143)
        assert not marker.exists(), ('task started after interrupt', sig, p.stderr)
        assert b'drain timeout' not in p.stderr, p.stderr

    # First-finish returns the winner's status, including success, and forces
    # both remaining groups to exit when they ignore SIGTERM.
    for status in (0, 23):
        names = [f'hold-{status}-{index}' for index in range(2)]
        task_file([task_worker('family', name) for name in names] +
                  [task_worker('winner', 'winner', str(status), *names)],
                  stop_on_first_finish=True)
        started = time.monotonic()
        capture_output('--tasks', str(tasks_path), code=status)
        assert time.monotonic() - started >= 1.8
        for name in names:
            pid = int((root / name).read_text())
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                pass
            else:
                raise AssertionError(f'task {pid} was not reaped')
            # An orphan can remain a zombie until the host reaps it. It must
            # not be running, and it must no longer hold our output pipes.
            child = int((root / (name + '.child')).read_text())
            state = subprocess.run(['ps', '-o', 'stat=', '-p', str(child)],
                                   capture_output=True, text=True, timeout=5).stdout.strip()
            assert not state or state.startswith('Z'), (child, state)

    # Interrupt every group, including when estimates are enabled.
    names = ['signal-one', 'signal-two']
    task_file([task_worker('hold', name, guess=True) for name in names])
    p = subprocess.Popen([exe, '--tasks', str(tasks_path)], env=env,
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        deadline = time.monotonic() + 5
        while not all((root / name).exists() for name in names):
            assert time.monotonic() < deadline, 'tasks did not start'
            time.sleep(.01)
        p.send_signal(signal.SIGINT)
        stdout, stderr = p.communicate(timeout=8)
        assert (p.returncode, stdout, stderr) == (130, b'', b'')
        for name in names:
            try:
                os.kill(int((root / name).read_text()), 0)
            except ProcessLookupError:
                pass
            else:
                raise AssertionError('interrupted task was not reaped')
    finally:
        if p.poll() is None:
            p.kill()
            p.wait()

    # Launch failure must terminate a task already blocked on output.
    task_file([dict(command=[sys.executable, fixture, 'volume']),
               dict(command=['zpg-command-that-does-not-exist'])])
    capture_output('--tasks', str(tasks_path), code=1)
    if sys.platform.startswith('linux'):
        task_file([dict(command=[sys.executable, fixture, 'volume']) for _ in range(2)])
        with open('/dev/full', 'wb') as sink:
            p = subprocess.run([exe, '--tasks', str(tasks_path)], stdout=sink,
                               stderr=subprocess.PIPE, env=env, timeout=8)
        assert p.returncode == 1

    task_file([task_worker('progress', 'native-one', name='one'),
               task_worker('progress', 'native-two', name='two', guess=True)])
    for prefix in ([], ['--renderer', 'tree'], [exe]):
        capture = terminal_capture([*prefix, '--tasks', str(tasks_path)], rows=25,
                                   checkpoints=[('tasks-visible',
                                                 rb'tasks.*native-one.*native-two')])
        assert b'tasks' in capture and b'native-one' in capture and b'native-two' in capture
        assert b'I/O estimate' in capture and progress_cleared(capture), capture
    capture = terminal_capture(['--no-progress', '--tasks', str(tasks_path)])
    assert capture == b'', capture

    # The root counts completed commands, regardless of each native report's
    # own item count. Keep the second command alive until 1/2 is displayed.
    task_file([task_worker('progress', 'native-one', 'first', name='one'),
               task_worker('progress', 'native-two', 'second', name='two')])
    capture = terminal_capture(['--tasks', str(tasks_path)],
                               checkpoints=[('first', rb'tasks.*native-one.*native-two'),
                                            ('second', rb'tasks .*50% 1/2.*native-two')])
    assert progress_cleared(capture), capture

print('parallel tasks checks passed')
