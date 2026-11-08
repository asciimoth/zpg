import os
import signal
import sys
import time

mode = sys.argv[1]
if mode == 'args':
    print(repr(sys.argv[2:]))
    print('stdin=' + repr(sys.stdin.read()))
    print('tty=' + repr((os.isatty(1), os.isatty(2))))
elif mode == 'bytes':
    os.write(int(sys.argv[2]), b'first\n\nlast\r\x1b[31m\x00' + bytes(range(256)) + b'x' * 20000)
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
