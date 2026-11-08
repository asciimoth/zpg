"""Behavior checks for pipes, process cleanup, and stdlib terminal progress."""
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
fixture = str(pathlib.Path(__file__).parent / 'fixtures' / 'worker.py')
env = dict(os.environ, PATH=str(pathlib.Path(exe).parent) + os.pathsep + os.environ['PATH'])

def run(*args, code=0):
    p = subprocess.run([exe, *args], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                       env=env, timeout=15)
    assert p.returncode == code, (args, p.returncode, p.stderr)
    assert p.stdout == b'', p.stdout
    return p.stderr

def worker(mode, *args, code=0):
    return run('--name', 'worker', sys.executable, fixture, mode, *args, code=code)

for args in [(), ('--bad',), ('--name',), ('--mock', 'true')]:
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
