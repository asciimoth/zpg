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

elif mode == 'test-progress':
    import struct
    fd = int(os.environ['ZIG_PROGRESS'])
    def packet(nodes):
        return (bytes([len(nodes)]) + b''.join(
            struct.pack('<II120s', completed, total, name)
            for completed, total, name, parent in nodes)
            + bytes(parent for completed, total, name, parent in nodes))
    kind = sys.argv[2]
    data = packet([(0, 4, b'work', 255), (1, 0, b'child\n\x1b', 0)])
    if kind == 'invalid':
        data = data[:-1] + b'\x01'
    elif kind == 'truncated':
        data = data[:-3]
    os.write(fd, data[:7])
    os.write(fd, data[7:])
    if kind == 'valid':
        os.write(fd, data)
        os.write(fd, packet([(4, 4, b'work', 255)]))
        os.write(fd, b'\x00')
    os.write(1, b'child stdout\x00')
    os.write(2, b'child stderr\n')
elif mode == 'controls':
    import struct
    fd = int(sys.argv[2])
    if 'ZIG_PROGRESS' in os.environ:
        os.write(int(os.environ['ZIG_PROGRESS']),
                 struct.pack('<BII120sB', 1, 1, 2, b'control progress', 255))
    # Fill a small terminal before drawing, so zpg must also scroll its overlay.
    os.write(fd, b'log\n' * 10)
    time.sleep(.3)
    for chunk in [
        b'abcdefghij\rXY',
        b'\r\x1b[2Kbar 100%\n',
        b'footer old\nitems 0/2\r\x1b[A',
        b'\x1b[',  # Force a display tick inside an incomplete CSI sequence.
        b'2Kfooter done\x1b[B\r\x1b[2Kitems 2/2\x1b[A\r',
        b'\x1b[B\r\nsaved: \x1b7\nscratch',
        b'\r\x1b[2K\x1b8restored\n',
        b'backspacX\be\tend\n',
        b'\x1b[32mwide: \xe7',  # Split a UTF-8 character as well.
        b'\x95\x8c\x1b[0m',
        ' complete café e\u0301\n'.encode(),
    ]:
        os.write(fd, chunk)
        time.sleep(.08)
