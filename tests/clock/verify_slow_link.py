#!/usr/bin/env python3
"""Run in the existing --network=none builder. NTP on private loopback only.

chronyd -Q disables clock control. The fake server queues each reply for four
seconds after stamping it, simulating network delay, not server processing.
No host clock, chrony service, network configuration, or tablet is touched.
"""
import json
import shutil
import socket
import struct
import subprocess
import threading
import time


def stamp(now):
    return int((now + 2208988800) * 2**32)


def main():
    binary = shutil.which('chronyd')
    if not binary:
        raise SystemExit('chronyd is required in the offline builder')
    stop = threading.Event()
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as server:
        server.bind(('127.0.0.1', 0))
        server.settimeout(0.1)
        port = server.getsockname()[1]

        def reply(packet, peer):
            now = time.time()
            response = struct.pack('!BBBbIIIQQQQ', 0x24, 1, 6, -20,
                                   0, 655, 0x47505300, stamp(now-10),
                                   struct.unpack_from('!Q', packet, 40)[0],
                                   stamp(now), stamp(now+0.001))
            if not stop.wait(4):
                try:
                    server.sendto(response, peer)
                except OSError:
                    pass

        def receive():
            while not stop.is_set():
                try:
                    packet, peer = server.recvfrom(512)
                except socket.timeout:
                    continue
                if len(packet) >= 48:
                    threading.Thread(target=reply, args=(packet, peer), daemon=True).start()

        thread = threading.Thread(target=receive)
        thread.start()
        results = []
        try:
            for allowed in (3, 10):
                config = f'server 127.0.0.1 port {port} maxsamples 1 maxdelay {allowed}'
                run = subprocess.run([binary, '-Q', '-t', '12', 'maxdistance 6',
                                      'maxjitter 2', config],
                                     capture_output=True, text=True, timeout=16)
                results.append({'maxdelay_s': allowed, 'returncode': run.returncode,
                                'output': run.stdout + run.stderr})
        finally:
            stop.set()
            thread.join(timeout=1)
        assert results[0]['returncode'] != 0, results
        assert results[1]['returncode'] == 0, results
        print(json.dumps({'mode': 'query-only, isolated loopback, queued 4s reply',
                          'results': results}, indent=2))


if __name__ == '__main__':
    main()
