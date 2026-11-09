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
import tempfile
import time

exe = str(pathlib.Path(sys.argv[1]).resolve())
render_probe = str(pathlib.Path(sys.argv[2]).resolve())
fixture = str(pathlib.Path(__file__).parent / 'fixtures' / 'worker.py')
report_demo = str(pathlib.Path(__file__).parent.parent / 'examples' / 'report-demo.sh')
env = dict(os.environ, PATH=str(pathlib.Path(exe).parent) + os.pathsep + os.environ['PATH'])
env.pop('UNICODE_PROGRESS_BAR', None)

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
    pid = int(p.stdout.readline())
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
# A descendant can keep inherited capture pipes open after zpg exits. Use files
# so the elapsed time measures zpg's exit, not the descendant's pipe lifetime.
with tempfile.TemporaryFile() as stdout, tempfile.TemporaryFile() as stderr:
    start = time.monotonic()
    p = subprocess.run([exe, '--name', 'worker', sys.executable, fixture,
                        'descendant'], stdout=stdout, stderr=stderr, env=env,
                       timeout=15)
    elapsed = time.monotonic() - start
    stdout.seek(0)
    stderr.seek(0)
    log = stderr.read()
    assert p.returncode == 0 and stdout.read() == b'parent done\n', (p.returncode, log)
    assert b'pipe drain timeout' in log and elapsed < 3.5, (elapsed, log)
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
# Ctrl-C must stop a mock even when its input pipe remains open and idle.
for initial in (b'', b'first\n'):
    p = subprocess.Popen([exe, '--mock'], stdin=subprocess.PIPE,
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
    try:
        if initial:
            p.stdin.write(initial)
            p.stdin.flush()
        time.sleep(.2)
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
assert b'mock stdout:' in p.communicate(timeout=2)[0] and b'mock stderr:' in log
assert b'[zpg:' not in log and b'exited with code' not in log
master, slave = pty.openpty()
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 24, 100, 0, 0))
p = subprocess.Popen([exe, '--no-progress', 'zpg', '--mock'], stdout=slave, stderr=slave, env=terminal_env)
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
                     stop_after=None, code=0, stdout_pattern=None, stdin=subprocess.DEVNULL):
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', rows, cols, 0, 0))
    child_env = dict(terminal_env, **(extra_env or {}))
    process = subprocess.Popen([exe, *args],
                               stdout=slave if stdout_pattern is None else subprocess.PIPE,
                               stdin=stdin, stderr=slave, env=child_env)
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
        if stdout_pattern is not None:
            assert re.fullmatch(stdout_pattern, stdout, re.S), stdout
        return bytes(captured)
    finally:
        os.close(master)
        if process.poll() is None:
            process.kill()
            process.wait()


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
    os.write(input_write, b'alpha\nbeta\ngamma\n')
finally:
    os.close(input_write)
try:
    capture = terminal_capture(['--mock'], stdin=input_read,
                               stdout_pattern=b'alpha\nbeta\ngamma\n')
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
            capture = terminal_capture(['--guess', *command], cols=120)
            assert b'I/O estimate (bytes): input.bin' in capture, capture
            assert b'25% 256/1024' in capture, capture
            assert b'75% 768/1024' in capture, capture
            last_known = capture.rfind(b'75% 768/1024')
            assert b'I/O estimate (unknown)' in capture[last_known:], capture
            logs = re.sub(rb'\x1b\[\?2026h.*?\x1b\[\?2026l', b'', capture, flags=re.S)
            assert logs.replace(b'\x1b[J', b'') == b'copy step\r\n' * 2, logs
        capture = terminal_capture(['--guess', '--renderer', 'tree', *args])
        assert b'I/O estimate (bytes): input.bin' in capture, capture
        capture = terminal_capture(['--guess', '--no-progress', *args])
        assert capture == b'copy step\r\n' * 2, capture
        assert run('--guess', *args) == b'copy step\n' * 2
        capture = terminal_capture(['--guess', sys.executable, fixture,
                                    'output-only', str(source) + '.out'])
        assert b'I/O estimate (unknown)' in capture and b'100%' not in capture, capture
        capture = terminal_capture(['--guess', *args], stop_after=.8, code=130)
        assert b'25% 256/1024' in capture and capture.endswith(b'\x1b[J'), capture
        # Descriptors can close after a proc entry opens. Such races must not
        # add diagnostics or debug stack traces to the command's log.
        capture = terminal_capture(['--guess', sys.executable, fixture,
                                    'file-churn', str(source)])
        logs = re.sub(rb'\x1b\[\?2026h.*?\x1b\[\?2026l', b'', capture, flags=re.S)
        assert logs.replace(b'\x1b[J', b'') == b'churn complete\r\n', logs
        # File names must not inject terminal controls in either renderer.
        unusual = pathlib.Path(directory) / 'line\n\x1b[2Jé.bin'
        unusual.write_bytes(b'x' * 1024)
        for renderer in ('bars', 'tree'):
            capture = terminal_capture(['--guess', '--renderer', renderer,
                                        sys.executable, fixture, 'file-io', str(unusual)],
                                       cols=120)
            assert 'line??[2Jé.bin'.encode() in capture, capture
            assert b'\x1b[2J' not in capture, capture
        # Sparse files exercise >4 GiB counts without substantial disk use.
        with source.open('wb') as sparse:
            sparse.truncate(1 << 34)
        capture = terminal_capture(['--guess', sys.executable, fixture,
                                    'file-seek', str(source)], cols=120)
        assert b'I/O estimate (KiB): input.bin' in capture, capture
        assert b'25% 4194304/16777216' in capture, capture
        assert b'75% 12582912/16777216' in capture, capture

# Native reports remain usable when the separate I/O estimate is enabled.
capture = terminal_capture(['--guess', 'sh', '-c',
                            'zpg --report 1 4 --name native; sleep .65'])
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
# The demo can exit before its final report is drawn. Check completion and
# drawing here; the report fixture below keeps exact counts visible before exit.
demo_capture = terminal_capture(['--name', 'shell demo', 'sh', report_demo])
assert b'\x1b[?2026h' in demo_capture, demo_capture
assert b'shell demo: complete\r\n' in demo_capture, demo_capture
for worker_name in (b'indexer', b'compiler', b'uploader'):
    assert worker_name + b': build' in demo_capture, (worker_name, demo_capture)
# Reports must remain visible after each short-lived reporter exits, and
# reach either renderer through a nested supervisor.
report_script = ('set -e; zpg --report 1 4; sleep .5; '
                 'zpg --report 3 4 --name compile; sleep .5; '
                 'zpg --report 4 4 --name done; sleep .5')
for prefix in [[], [exe]]:
    report_capture = terminal_capture([*prefix, '--name', 'script', 'sh', '-c', report_script])
    assert b'script [###---------] 25% 1/4' in report_capture, report_capture
    assert b'compile [#########---] 75% 3/4' in report_capture, report_capture
    assert b'done [############] 100% 4/4' in report_capture, report_capture
report_capture = terminal_capture(['--renderer', 'tree', 'sh', '-c', report_script])
assert b'compile' in report_capture and b'done' in report_capture, report_capture
report_capture = terminal_capture(['--no-progress', 'sh', '-c', report_script])
assert report_capture == b'', report_capture
assert run('--renderer', 'bars', render_probe) == expected_logs
capture = terminal_capture([render_probe], rows=8)
frames = re.findall(rb'\x1b\[\?2026h(.*?)\x1b\[\?2026l', capture, re.S)
assert frames
assert any(b'[#########---] 75% 3/4' in frame for frame in frames)
assert any(b'[############] 100% 7/4' in frame for frame in frames)
spinner_frames = set(re.findall(rb'unknown ([|/\\-]) 2 done', capture))
assert len(spinner_frames) > 1, spinner_frames
assert b'unsafe?[2J label?' in capture
assert b'\x1b[2J' not in capture and '\u202e'.encode() not in capture
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
capture = terminal_capture([*custom_args, '--mock'], stop_after=.8, code=130,
                           stdout_pattern=rb'(mock stdout: work in progress\n|mock worker: processing item\n)+')
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


# Give stdout and stderr different terminals so the tests can identify exactly
# which descriptor receives progress. Non-terminal streams go to real files.
def capture_destinations(args, stdout_tty, stderr_tty, stdin=subprocess.DEVNULL,
                         extra_env=None):
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
                attributes[1] &= ~termios.OPOST
                termios.tcsetattr(slave, termios.TCSANOW, attributes)
                destinations[name] = slave
            else:
                files[name] = tempfile.TemporaryFile()
                destinations[name] = files[name]
        process = subprocess.Popen([exe, *args], stdin=stdin, **destinations,
                                   env=dict(terminal_env, **(extra_env or {})))
        for _, slave in terminals.values():
            os.close(slave)
        active = {master: name for name, (master, _) in terminals.items()}
        deadline = time.monotonic() + 5
        while active:
            assert time.monotonic() < deadline, 'stream selection test timed out'
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
                else:
                    del active[master]
        assert process.wait(timeout=5) == 0
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


stream_script = ('printf "stdout marker\\n"; printf "stderr marker\\n" >&2; '
                 'zpg --report 1 2 --name stream-progress; sleep .3; '
                 'printf "stdout tail\\n"; printf "stderr tail\\n" >&2; sleep .15')
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
        args = ['--renderer', renderer, '--progress-stream', choice, 'sh', '-c', stream_script]
        captures = capture_destinations(args, stdout_tty, stderr_tty)
        for name, data in captures.items():
            marker = (name + ' marker\n').encode()
            if name == selected:
                assert b'\x1b' in data and b'stream-progress' in data, (args, name, data)
                assert marker in data and (name + ' tail\n').encode() in data, (args, name, data)
                assert (('stderr' if name == 'stdout' else 'stdout') + ' marker').encode() not in data
            else:
                assert data == marker + (name + ' tail\n').encode(), (args, name, data)
    for options, overrides in [(['--no-progress'], {}), ([], {'TERM': 'dumb'})]:
        captures = capture_destinations(['--renderer', renderer, *options, 'sh', '-c', stream_script],
                                        True, True, extra_env=overrides)
        assert captures == dict(stdout=b'stdout marker\nstdout tail\n', stderr=b'stderr marker\nstderr tail\n'), captures
    # The outer process selects the terminal, even with conflicting inner flags.
    captures = capture_destinations(['--renderer', renderer, '--progress-stream', 'stdout',
                                     exe, '--progress-stream', 'stderr', 'sh', '-c', stream_script],
                                    True, True)
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
            captures = capture_destinations(['--renderer', renderer, *prefix, 'sh', '-c',
                                             'cat; zpg --report 1 2 --name input-progress; sleep .4'],
                                            False, True, stdin=read_fd)
        finally:
            os.close(read_fd)
        assert captures['stdout'] == input_bytes
        assert b'input-progress' in captures['stderr'] and b'\x1b' in captures['stderr']
print('separate streams and progress terminal selection checks passed')

# The same terminal can be reached by both descriptors. Verify that stdout
# progress also preserves partial log lines when the overlay causes scrolling.
capture = terminal_capture(['--progress-stream', 'stdout', render_probe], rows=8)
visible_logs = [line for line in replay_terminal(capture, 8, 80) if line]
assert visible_logs == expected_logs.decode().splitlines(), visible_logs
