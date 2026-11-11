"""Controlled generic I/O workloads. No application progress output."""
import os
import socket
import sys
import threading
from contextlib import ExitStack
from sync import checkpoint


mode = sys.argv[1]
if mode == 'parallel':
    with ExitStack() as stack:
        files = [stack.enter_context(open(path, 'rb', buffering=0))
                 for path in sys.argv[2:]]
        duplicate = stack.enter_context(os.fdopen(os.dup(files[0].fileno()), 'rb'))
        # Establish zero offsets, including the much larger idle input.
        checkpoint('open')
        files[0].read(256)
        files[1].read(1024)
        checkpoint('parallel')
        files[0].read(256)
        files[1].read(512)
        checkpoint('advance')
        files[0].close()
        duplicate.close()
        checkpoint('single')
        source = stack.enter_context(open(sys.argv[2], 'rb', buffering=0))
        files[1].read(128)
        done = threading.Event()

        def read_reopened_file():
            while not done.wait(.05):
                source.read(16)

        thread = threading.Thread(target=read_reopened_file)
        thread.start()
        try:
            checkpoint('parallel-again')
        finally:
            done.set()
            thread.join()
    checkpoint('closed')
elif mode == 'many':
    with ExitStack() as stack:
        files = [stack.enter_context(open(path, 'rb', buffering=0))
                 for path in sys.argv[2:]]
        checkpoint('open')
        for source in files:
            source.read(256)
        checkpoint('many')
elif mode in ('backward', 'growing', 'eof'):
    with open(sys.argv[2], 'rb', buffering=0) as source:
        checkpoint('open')
        source.read(256)
        checkpoint('read')
        if mode == 'backward':
            source.seek(128)
        elif mode == 'growing':
            with open(sys.argv[2], 'ab') as target:
                target.write(b'x' * 1024)
        else:
            source.read()
        checkpoint('unknown')
elif mode == 'pread':
    with open(sys.argv[2], 'rb', buffering=0) as source:
        checkpoint('open')
        done = threading.Event()

        def read_without_position():
            while not done.wait(.01):
                os.pread(source.fileno(), 1024, 0)

        thread = threading.Thread(target=read_without_position)
        thread.start()
        try:
            checkpoint('activity')
        finally:
            done.set()
            thread.join()
        assert source.tell() == 0
elif mode == 'tcp':
    with ExitStack() as stack:
        family = socket.AF_INET6 if sys.argv[2:] == ['ipv6'] else socket.AF_INET
        address = '::1' if family == socket.AF_INET6 else '127.0.0.1'
        listener = stack.enter_context(socket.socket(family))
        listener.bind((address, 0))
        listener.listen()
        sender = stack.enter_context(socket.socket(family))
        sender.connect(listener.getsockname())
        receiver, _ = listener.accept()
        stack.enter_context(receiver)
        # Wait until the TCP sampler has a baseline for these sockets.
        checkpoint('connected')
        sender.sendall(b'x' * 32768)
        remaining = 32768
        while remaining:
            remaining -= len(receiver.recv(remaining))
        checkpoint('transferred')
elif mode == 'cpu':
    done = threading.Event()

    def compute():
        while not done.is_set():
            sum(range(10000))

    thread = threading.Thread(target=compute)
    thread.start()
    try:
        checkpoint('activity')
    finally:
        done.set()
        thread.join()
