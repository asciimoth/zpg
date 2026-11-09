import os
import signal
import stat
import sys
import time

mode = sys.argv[1]
if mode == 'args':
    print(repr(sys.argv[2:]))
    print('stdin=' + repr(sys.stdin.read()))
    print('tty=' + repr((os.isatty(1), os.isatty(2))))
elif mode == 'bytes':
    os.write(int(sys.argv[2]), b'first\n\nlast\r\x1b[31m\x00' + bytes(range(256)) + b'x' * 20000)
elif mode == 'tty':
    for fd in (1, 2):
        terminal = os.isatty(fd)
        label = f'fd={fd} tty={terminal}'.encode()
        if terminal:
            size = os.get_terminal_size(fd)
            label += f' size={size.columns}x{size.lines}'.encode()
            label = b'\x1b[32m' + label + b'\x1b[0m'
        os.write(fd, label + b'\n')
elif mode == 'stdin':
    while chunk := sys.stdin.buffer.read(4096):
        sys.stdout.buffer.write(chunk)
        sys.stdout.buffer.flush()
elif mode == 'volume':
    for i in range(3000):
        token = bytes(97 + int(digit, 16) for digit in format(i, '08x'))
        os.write(1, token + b'q')
        os.write(2, token.upper() + b'Q')
    os.write(1, b'x' * 20000)
elif mode == 'partial':
    os.write(1, b'working\r')
    while True:
        time.sleep(1)
elif mode == 'exit':
    sys.exit(37)
elif mode == 'progress-env':
    value = os.environ.get('ZIG_PROGRESS')
    if value is None:
        print('progress pipe: absent')
    else:
        fd = int(value)
        assert os.get_inheritable(fd), 'progress descriptor is not inheritable'
        assert stat.S_ISFIFO(os.fstat(fd).st_mode), 'progress descriptor is not a pipe'
        print('progress pipe: open')
elif mode in ('stop', 'stubborn'):
    if mode == 'stubborn':
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
    print(os.getpid(), flush=True)
    while True:
        time.sleep(1)
elif mode == 'descendant':
    pid = os.fork()
    if pid == 0:
        time.sleep(4)
        os._exit(0)
    print('parent done', flush=True)
elif mode == 'signal':
    os.kill(os.getpid(), signal.SIGTERM)
elif mode in ('file-io', 'file-seek'):
    path = sys.argv[2]
    size = os.stat(path).st_size
    # A larger output must not replace the input estimate. Use an unbuffered
    # reader so the descriptor position matches each test step exactly.
    with open(path, 'rb', buffering=0) as source, open(path + '.out', 'wb') as target:
        target.truncate(size * 2)
        for fraction in (1, 3):
            position = size * fraction // 4
            if mode == 'file-seek':
                source.seek(position)
            else:
                source.read(position - source.tell())
            os.write(1, b'copy step\n')
            time.sleep(.65)
    # The estimate must return to unknown after the input closes.
    time.sleep(.65)
elif mode == 'output-only':
    with open(sys.argv[2], 'wb') as target:
        target.write(b'x' * 4096)
        target.flush()
        time.sleep(.65)
elif mode == 'file-churn':
    deadline = time.monotonic() + 1
    while time.monotonic() < deadline:
        with open(sys.argv[2], 'rb', buffering=0) as source:
            source.read(256)
    print('churn complete')
