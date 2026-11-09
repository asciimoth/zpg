"""Emit exact chunks and wait for the test to inspect each terminal state."""
import json
import os
import socket
import struct
import sys

socket_path, plan_path, destination = sys.argv[1:]
with open(plan_path) as plan:
    chunks = json.load(plan)
with socket.socket(socket.AF_UNIX) as control:
    control.connect(socket_path)
    progress = os.environ.get('ZIG_PROGRESS')
    if progress is not None:
        os.write(int(progress), struct.pack('<BII120sB', 1, 1, 2, b'__overlay__', 255))
    control.sendall(b'ready\n')
    assert control.recv(1) == b'!'
    for chunk in chunks:
        if isinstance(chunk, dict):
            if progress is not None and 'nodes' in chunk:
                count = chunk['nodes']
                packet = (bytes([count]) + struct.pack('<II120s', 1, 2, b'__overlay__') * count
                          + bytes([255]) + bytes(count - 1))
                os.write(int(progress), packet)
            chunk = chunk['data']
        data = bytes.fromhex(chunk)
        while data:
            data = data[os.write(int(destination), data):]
        control.sendall(b'stage\n')
        assert control.recv(1) == b'!'
