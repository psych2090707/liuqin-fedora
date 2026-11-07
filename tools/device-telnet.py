#!/usr/bin/env python3
"""Run one command in the liuqin RAM-installer / rescue BusyBox shell over USB NCM telnet.

The RAM shell is BusyBox ash behind telnetd at 192.168.7.2:2323 (development
channel; unauthenticated root).  This is the host-side lens into a tablet that
is running a liuqin RAM image but has no working desktop yet.

Usage
-----
  tools/device-telnet.py --cmd 'uname -a; cat /proc/cmdline'
  tools/device-telnet.py --cmd 'ls -l /dev/block/by-name' --timeout 30
  tools/device-telnet.py --cmd 'sh -c "..."' --raw      # no shell framing
  tools/device-telnet.py --serve 8000 --out /tmp/fw.img  # see --help

The framing (start/end markers around `sh -c`) is copied from
installer/install.py: BusyBox ash refuses input lines of 1024 bytes or more,
so this tool refuses to send an oversized line instead of silently truncating.
"""

import argparse
import re
import socket
import shlex
import sys
import uuid


RAM_SHELL_LINE_BYTES = 1023


def frame_command(text, start, end):
    line = ("stty -echo; printf '\\n%s\\n' " + shlex.quote(start) +
            '; sh -c ' + shlex.quote(text) +
            "; result=$?; printf '\\n%s %s\\n' " + shlex.quote(end) +
            ' "$result"\n').encode()
    if len(line) > RAM_SHELL_LINE_BYTES:
        raise SystemExit(
            f'remote command line is {len(line)} bytes; the RAM shell accepts at most'
            f' {RAM_SHELL_LINE_BYTES} including the newline, so it was not sent. '
            'Wrap large work in a script and upload it (base64) first.')
    return line


def run(address, text, timeout=120):
    token = 'LIUQIN_' + uuid.uuid4().hex
    start, end = token + '_START', token + '_END'
    line = frame_command(text, start, end)
    with socket.create_connection((address, 2323), timeout=10) as connection:
        connection.settimeout(1)
        connection.sendall(b'\xff\xfd\x01\xff\xfd\x03\xff\xfc\x1f')
        connection.sendall(line)
        buffer = bytearray()
        import time
        deadline = time.monotonic() + timeout
        pattern = re.compile(rb'(?:^|\n)' + end.encode() + rb' ([0-9]+)\r?\n')
        while time.monotonic() < deadline:
            try:
                chunk = connection.recv(65536)
            except socket.timeout:
                continue
            if not chunk:
                break
            buffer.extend(chunk)
            match = pattern.search(buffer, max(0, len(buffer) - 512))
            if match:
                first = re.search(rb'(?:^|\n)' + start.encode() + rb'\r?\n', buffer)
                body = b'' if not first else bytes(buffer[first.end():match.start()])
                body = body.replace(b'\r\n', b'\n').removesuffix(b'\r')
                code = int(match[1])
                sys.stdout.buffer.write(body)
                sys.stdout.buffer.flush()
                return code
    raise SystemExit('device shell timed out or the connection closed (device not running a RAM image?)')


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--device-address', default='192.168.7.2')
    parser.add_argument('--cmd', help='command line to run in the RAM shell')
    parser.add_argument('--timeout', type=float, default=120)
    parser.add_argument('--quiet-ok', action='store_true', help='exit 0 even if the remote exit code is nonzero')
    args = parser.parse_args()
    if not args.cmd:
        parser.error('--cmd is required')
    code = run(args.device_address, args.cmd, args.timeout)
    sys.exit(0 if (code == 0 or args.quiet_ok) else code)


if __name__ == '__main__':
    main()
