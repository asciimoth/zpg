"""Behavior checks for pipes, process cleanup, and terminal progress."""
import errno
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
import time

exe = str(pathlib.Path(sys.argv[1]).resolve())
render_probe = str(pathlib.Path(sys.argv[2]).resolve())
fixture = str(pathlib.Path(__file__).parent / 'fixtures' / 'worker.py')
env = dict(os.environ, PATH=str(pathlib.Path(exe).parent) + os.pathsep + os.environ['PATH'])
env.pop('UNICODE_PROGRESS_BAR', None)

def run(*args, code=0):
    p = subprocess.run([exe, *args], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                       env=env, timeout=15)
    assert p.returncode == code, (args, p.returncode, p.stderr)
    assert p.stdout == b'', p.stdout
    return p.stderr

def worker(mode, *args, code=0):
    return run('--name', 'worker', sys.executable, fixture, mode, *args, code=code)

for args in [(), ('--bad',), ('--name',), ('--mock', 'true'),
             ('--renderer',), ('--renderer', 'bad', 'true'),
             ('--bar-style',), ('--spinner-style',),
             ('--bar-style', 'bad', 'true'),
             ('--bar-style', '#\n', 'true'),
             ('--spinner-style', '', 'true'),
             ('--spinner-style', '\x1b[2J', 'true')]:
    run(*args, code=2)
assert b'Usage:' in run('--help')
run('zpg-command-that-does-not-exist', code=1)
log = worker('args', '--flag', 'a b', '', '$(false)')
assert b"['--flag', 'a b', '', '$(false)']" in log
assert b"stdin=''" in log and b'tty=(False, False)' in log
# Neither pipe may gain labels, newlines, or a final status message.
payload = b'first\n\nlast\r\x1b[31m\x00' + bytes(range(256)) + b'x' * 20000
for fd in ('1', '2'):
    assert worker('bytes', fd) == payload
assert run('true') == b''
log = worker('volume')
# Distinct alphabets let us check per-pipe order even if chunks interleave
# in the middle of a write. The child fills both pipes without any LF bytes.
expected = b''.join(bytes(97 + int(digit, 16) for digit in format(i, '08x')) + b'q'
                    for i in range(3000))
assert bytes(c for c in log if 97 <= c <= 122) == expected + b'x' * 20000
assert bytes(c for c in log if 65 <= c <= 90) == expected.upper()
assert len(log) == 2 * len(expected) + 20000
# A partial line must reach the output while the child is still running.
p = subprocess.Popen([exe, '--no-progress', sys.executable, fixture, 'partial'],
                     stdout=subprocess.PIPE, stderr=subprocess.PIPE)
try:
    ready, _, _ = select.select([p.stderr], [], [], 5)
    assert ready, 'partial output was buffered until EOF'
    partial = os.read(p.stderr.fileno(), 4096)
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
    with open('/dev/full', 'wb') as sink:
        p = subprocess.run([exe, sys.executable, fixture, 'volume'], stderr=sink,
                           stdout=subprocess.PIPE, timeout=8)
    assert p.returncode == 1
    with open('/dev/full', 'wb') as sink:
        p = subprocess.run([exe, '--mock'], stderr=sink,
                           stdout=subprocess.PIPE, timeout=8)
    assert p.returncode == 1
assert worker('exit', code=37) == b''
assert worker('signal', code=143) == b''
for sig, mode in [(signal.SIGINT, 'stop'), (signal.SIGTERM, 'stop'), (signal.SIGINT, 'stubborn')]:
    p = subprocess.Popen([exe, sys.executable, fixture, mode], stderr=subprocess.PIPE, stdout=subprocess.PIPE)
    ready, _, _ = select.select([p.stderr], [], [], 5)
    assert ready
    pid = int(p.stderr.readline())
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
start = time.monotonic()
log = worker('descendant')
assert b'pipe drain timeout' in log and time.monotonic() - start < 3.5
log = run('zpg', '--mock')
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
run('--no-progress', 'zpg', '--mock')
# An interrupt must stop and reap all three worker processes.
p = subprocess.Popen([exe, '--mock'], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                     bufsize=0)
worker_pids = set()
deadline = time.monotonic() + 8
while len(worker_pids) < 3 and time.monotonic() < deadline:
    ready, _, _ = select.select([p.stderr], [], [], .1)
    if ready:
        line = p.stderr.readline()
        match = re.search(rb'mock worker (?:indexer|compiler|uploader) \(pid (\d+)\): started', line)
        if match:
            worker_pids.add(int(match.group(1)))
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
# A PTY gives the renderer a real terminal, while child output remains piped.
master, slave = pty.openpty()
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 48, 100, 0, 0))
terminal_env = dict(env, TERM='xterm-256color')
terminal_env.pop('NO_COLOR', None)
terminal_env.pop('ZIG_PROGRESS', None)
p = subprocess.Popen([exe, 'zpg', '--mock'], stdout=subprocess.PIPE, stderr=slave, env=terminal_env)
os.close(slave)
log = bytearray()
deadline = time.monotonic() + 10
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
assert any(all(name in frame for name in
               (b'indexer', b'compiler', b'uploader')) for frame in frames)
for node in (b'discover', b'scan inputs', b'inspect metadata', b'build',
             b'assets', b'transform', b'compress', b'code', b'generate',
             b'resolve symbols', b'verify', b'publish', b'upload'):
    assert node in log, node
for node in (b'indexer batch', b'compiler batch', b'uploader batch'):
    assert node in log, node
assert b'mock stdout:' in log and b'mock stderr:' in log
assert b'[zpg:' not in log and b'exited with code' not in log
master, slave = pty.openpty()
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 24, 100, 0, 0))
p = subprocess.Popen([exe, '--no-progress', 'zpg', '--mock'], stderr=slave, env=terminal_env)
os.close(slave)
log = bytearray()
while True:
    ready, _, _ = select.select([master], [], [], 5)
    assert ready, 'no-progress terminal test timed out'
    try:
        data = os.read(master, 65536)
    except OSError as e:
        if e.errno == errno.EIO:
            break
        raise
    if not data:
        break
    log.extend(data)
os.close(master)
assert p.wait(timeout=2) == 0 and b'\x1b' not in log
print('integration checks passed (including terminal progress)')


def terminal_capture(args, rows=12, cols=80, extra_env=None, resize=None,
                     stop_after=None, code=0, stdout_pattern=b''):
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', rows, cols, 0, 0))
    child_env = dict(terminal_env, **(extra_env or {}))
    process = subprocess.Popen([exe, *args], stdout=subprocess.PIPE,
                               stderr=slave, env=child_env)
    os.close(slave)
    captured = bytearray()
    start = time.monotonic()
    resized = False
    stopped = False
    try:
        while time.monotonic() - start < 5:
            if stop_after and not stopped and time.monotonic() - start > stop_after:
                process.send_signal(signal.SIGINT)
                stopped = True
            if resize and not resized and time.monotonic() - start > .5:
                fcntl.ioctl(master, termios.TIOCSWINSZ,
                            struct.pack('HHHH', *resize, 0, 0))
                resized = True
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
        else:
            raise AssertionError('renderer terminal test timed out')
        stdout, _ = process.communicate(timeout=2)
        assert process.returncode == code, (process.returncode, captured)
        assert re.fullmatch(stdout_pattern, stdout, re.S), stdout
        return bytes(captured)
    finally:
        os.close(master)
        if process.poll() is None:
            process.kill()
            process.wait()


expected_logs = b'log line\n' * 12 + b'partial continued\n'
assert run('--renderer', 'bars', render_probe) == expected_logs
capture = terminal_capture([render_probe], rows=8)
frames = re.findall(rb'\x1b\[\?2026h(.*?)\x1b\[\?2026l', capture, re.S)
assert frames
assert any(b'[#########---] 75% 3/4' in frame for frame in frames)
assert any(b'[############] 100% 7/4' in frame for frame in frames)
spinner_frames = set(re.findall(rb'unknown ([|/\\-]) 2 done', capture))
assert len(spinner_frames) > 1, spinner_frames
assert b'unsafe?[2J label' in capture and b'\x1b[2J' not in capture
# Removing whole drawing transactions must leave the original log bytes.
logs = re.sub(rb'\x1b\[\?2026h.*?\x1b\[\?2026l', b'', capture, flags=re.S)
assert logs.replace(b'\x1b[J', b'') == expected_logs.replace(b'\n', b'\r\n')
assert capture.endswith(b'\x1b[J'), 'the final progress tree was not cleared'

# Custom Unicode styles must preserve log bytes and render complete codepoints.
custom_args = ['--bar-style', 'block', '--spinner-style', '⠋⠙']
assert run(*custom_args, render_probe) == expected_logs
custom_capture = terminal_capture([*custom_args, render_probe])
assert ('█' * 9 + '    75% 3/4').encode() in custom_capture
assert ('█' * 12 + ' 100% 7/4').encode() in custom_capture
assert 'unknown ⠋ 2 done'.encode() in custom_capture
assert 'unknown ⠙ 2 done'.encode() in custom_capture
custom_logs = re.sub(rb'\x1b\[\?2026h.*?\x1b\[\?2026l', b'', custom_capture, flags=re.S)
assert custom_logs.replace(b'\x1b[J', b'') == expected_logs.replace(b'\n', b'\r\n')
custom_capture.decode('utf-8')
custom_capture = terminal_capture(['--bar-style', '(▓░)', '--spinner-style', 'ab', render_probe])
assert ('(' + '▓' * 9 + '░' * 3 + ') 75% 3/4').encode() in custom_capture
assert b'unknown a 2 done' in custom_capture and b'unknown b 2 done' in custom_capture
custom_capture = terminal_capture([*custom_args, render_probe], cols=24)
custom_frames = re.findall(rb'\x1b7[\r\n]+(.*?)\x1b8', custom_capture, re.S)
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
    fira_logs = re.sub(rb'\x1b\[\?2026h.*?\x1b\[\?2026l', b'', fira_capture, flags=re.S)
    assert fira_logs.replace(b'\x1b[J', b'') == expected_logs.replace(b'\n', b'\r\n')
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

# Replay the cursor operations to check partial lines even when drawing scrolls.
# This fixture uses ASCII and only the escape sequences emitted by our renderer.
def replay_terminal(data, rows, cols):
    screen = [[' '] * cols for _ in range(rows)]
    history = []
    row = col = 0
    saved = (0, 0)

    def down():
        nonlocal row
        row += 1
        if row == rows:
            history.append(''.join(screen.pop(0)).rstrip())
            screen.append([' '] * cols)
            row -= 1

    index = 0
    while index < len(data):
        byte = data[index]
        if byte == 27:
            if data[index + 1] == ord('['):
                match = re.match(rb'\x1b\[([?\d;]*)([A-Za-z])', data[index:])
                assert match, data[index:index + 30]
                param, command = match.groups()
                if command == b'A':
                    row = max(0, row - int(param or b'1'))
                elif command == b'J':
                    screen[row][col:] = [' '] * (cols - col)
                    for line in range(row + 1, rows):
                        screen[line] = [' '] * cols
                else:
                    assert (param, command) in [(b'?2026', b'h'), (b'?2026', b'l')]
                index += len(match.group())
                continue
            command = data[index + 1]
            if command == ord('D'):
                down()
            elif command == ord('7'):
                saved = (row, col)
            elif command == ord('8'):
                row, col = saved
            else:
                raise AssertionError(f'unknown escape: {command}')
            index += 2
            continue
        if byte == 13:
            col = 0
        elif byte == 10:
            down()
        else:
            assert col < cols, 'renderer wrapped a line'
            screen[row][col] = chr(byte)
            col += 1
        index += 1
    return history + [''.join(line).rstrip() for line in screen]


visible_logs = [line for line in replay_terminal(capture, 8, 80) if line]
assert visible_logs == expected_logs.decode().splitlines(), visible_logs
capture = terminal_capture([render_probe], stop_after=.55, code=130)
assert b'75% 3/4' in capture and capture.endswith(b'\x1b[J')

# A resize must constrain subsequent frames without a signal handler.
capture = terminal_capture([render_probe], rows=12, cols=80, resize=(5, 24))
frames = re.findall(rb'\x1b7[\r\n]+(.*?)\x1b8', capture, re.S)
assert frames
last_lines = frames[-1].replace(b'\r', b'').split(b'\n')
assert len(last_lines) <= 3 and all(len(line) < 24 for line in last_lines)
for size in [(3, 8), (1, 1)]:
    terminal_capture([render_probe], rows=size[0], cols=size[1])

# Nesting still sends progress to the outer process, which owns the display.
capture = terminal_capture([exe, render_probe])
assert b'[#########---] 75% 3/4' in capture
capture = terminal_capture([*custom_args, exe, '--bar-style', 'ascii', render_probe])
assert ('█' * 9 + '    75% 3/4').encode() in capture
assert b'[#########---]' not in capture
capture = terminal_capture([*custom_args, '--mock'], stop_after=.8, code=130,
                           stdout_pattern=rb'(mock stdout: work in progress\n)+')
assert '█'.encode() in capture
capture = terminal_capture(['--renderer', 'tree', render_probe])
assert b'\x1b' in capture and b'render probe' in capture
assert b'[#########---]' not in capture
capture = terminal_capture([render_probe], extra_env={'NO_COLOR': '1'})
assert b'[#########---] 75% 3/4' in capture
for args, overrides in [(['--no-progress', render_probe], {}),
                        (['--no-progress', *custom_args, render_probe], {}),
                        ([render_probe], {'TERM': 'dumb'})]:
    capture = terminal_capture(args, extra_env=overrides)
    assert b'\x1b' not in capture and capture == expected_logs.replace(b'\n', b'\r\n'), (args, overrides, capture)
print('custom renderer checks passed (including resize and partial log lines)')
