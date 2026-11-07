#!/usr/bin/env python3
"""AFK channel (TN0048) — minimal bootstrap DHCP server for the USB NCM link.

Why this exists
---------------
The initramfs installer stage ran udhcpd on the tablet, so the host's
NetworkManager got 192.168.7.10 automatically.  After the first boot into the
installed system that udhcpd is gone and the AFK overlay (which ships a real
dnsmasq) is not installed yet — so the tablet's NetworkManager sits there as a
DHCP *client* with no address, and SSH is unreachable.

This server answers exactly one client (the gadget's device-side MAC,
02:00:00:00:07:02) and only while the tool is running.  Once the overlay is
installed the tablet serves DHCP itself (afk-usb0-dhcp.service) and this is no
longer needed.

Deliberately NOT a general DHCP server: other clients (e.g. the host's own
dhclient on the same interface) are ignored, no lease file is written, and no
router/DNS options are offered so nothing starts routing through the tablet.

Usage (needs root for port 67):
    sudo tools/afk/dhcp-serve.py --iface enp0s20f0u2
    sudo tools/afk/dhcp-serve.py --iface enp0s20f0u2 --seconds 90 --verbose

The host itself still needs an address on the link (afk.sh up adds
192.168.7.10/24 with `ip addr replace`); this server does not configure it.
"""

from __future__ import annotations

import argparse
import socket
import struct
import sys
import time

DHCP_SERVER_PORT = 67
DHCP_CLIENT_PORT = 68
MAGIC_COOKIE = b"\x63\x82\x53\x63"

# DHCP message types (option 53)
DISCOVER = 1
OFFER = 2
REQUEST = 3
DECLINE = 4
ACK = 5
NAK = 6
RELEASE = 7
INFORM = 8

# DHCP options
OPT_SUBNET_MASK = 1
OPT_ROUTER = 3
OPT_DNS = 6
OPT_HOSTNAME = 12
OPT_REQUESTED_IP = 50
OPT_LEASE_TIME = 51
OPT_MSG_TYPE = 53
OPT_SERVER_ID = 54
OPT_PARAM_REQ = 55
OPT_T1 = 58
OPT_T2 = 59
OPT_END = 255


def log(msg: str, verbose: bool = True) -> None:
    if verbose:
        print(f"afk-dhcp: {msg}", file=sys.stderr, flush=True)


def parse_options(payload: bytes) -> dict[int, bytes]:
    """Parse the DHCP options field into {code: raw-value}."""
    opts: dict[int, bytes] = {}
    i = 0
    while i < len(payload):
        code = payload[i]
        if code == OPT_END:
            break
        if code == 0:  # padding
            i += 1
            continue
        if i + 1 >= len(payload):
            break
        length = payload[i + 1]
        value = payload[i + 2 : i + 2 + length]
        opts[code] = value
        i += 2 + length
    return opts


def mac_to_str(raw: bytes) -> str:
    return ":".join(f"{b:02x}" for b in raw)


def parse_packet(data: bytes) -> dict | None:
    """Parse a BOOTP/DHCP packet; returns None if it is not a DHCP request."""
    if len(data) < 240:
        return None
    op, htype, hlen, hops = struct.unpack("!BBBB", data[0:4])
    xid, secs, flags = struct.unpack("!IHH", data[4:12])
    ciaddr, yiaddr, siaddr, giaddr = struct.unpack("!IIII", data[12:28])
    chaddr = data[28:44][: min(hlen, 16)]
    if data[236:240] != MAGIC_COOKIE:
        return None
    options = parse_options(data[240:])
    msg_type = options.get(OPT_MSG_TYPE, b"\x00")[0]
    return {
        "op": op,
        "xid": xid,
        "secs": secs,
        "flags": flags,
        "ciaddr": ciaddr,
        "yiaddr": yiaddr,
        "giaddr": giaddr,
        "chaddr": chaddr,
        "mac": mac_to_str(chaddr),
        "msg_type": msg_type,
        "options": options,
    }


def build_reply(req: dict, msg_type: int, client_ip: str, server_ip: str,
                netmask: str, lease: int) -> bytes:
    """Build a BOOTREPLY carrying OFFER or ACK for one client."""
    op = 2  # BOOTREPLY
    htype = 1
    hlen = 6
    hops = 0
    xid = req["xid"]
    secs = 0
    # Broadcast flag: keep the client's request where it makes sense; NCM links
    # are point-to-point but NetworkManager expects a normal reply.
    flags = req.get("flags", 0)
    ciaddr = 0
    yiaddr = struct.unpack("!I", socket.inet_aton(client_ip))[0]
    siaddr = struct.unpack("!I", socket.inet_aton(server_ip))[0]
    giaddr = 0

    packet = struct.pack("!BBBB", op, htype, hlen, hops)
    packet += struct.pack("!IHH", xid, secs, flags)
    packet += struct.pack("!IIII", ciaddr, yiaddr, siaddr, giaddr)
    packet += req["chaddr"].ljust(16, b"\x00")
    packet += b"\x00" * 192  # sname (64) + file (128)
    packet += MAGIC_COOKIE

    options = b""
    options += bytes([OPT_MSG_TYPE, 1, msg_type])
    options += bytes([OPT_SERVER_ID, 4]) + socket.inet_aton(server_ip)
    options += bytes([OPT_LEASE_TIME, 4]) + struct.pack("!I", lease)
    options += bytes([OPT_SUBNET_MASK, 4]) + socket.inet_aton(netmask)
    # T1/T2: renew at 50% / 87.5% of the lease.
    options += bytes([OPT_T1, 4]) + struct.pack("!I", max(60, lease // 2))
    options += bytes([OPT_T2, 4]) + struct.pack("!I", max(120, int(lease * 0.875)))
    # Explicitly offer NO router and NO DNS: the tablet must not become a
    # gateway or resolver for the host.
    options += bytes([OPT_ROUTER, 0])
    options += bytes([OPT_DNS, 0])
    options += bytes([OPT_END])
    return packet + options


def main() -> int:
    ap = argparse.ArgumentParser(description="minimal DHCP server for the AFK USB NCM link")
    ap.add_argument("--iface", required=True, help="host interface facing the tablet (e.g. enp0s20f0u2)")
    ap.add_argument("--host-ip", default="192.168.7.10", help="host address (server identifier, default 192.168.7.10)")
    ap.add_argument("--client-ip", default="192.168.7.2", help="address to hand to the tablet (default 192.168.7.2)")
    ap.add_argument("--netmask", default="255.255.255.0")
    ap.add_argument("--allow-mac", default="02:00:00:00:07:02",
                    help="only serve this MAC (gadget device side); use 'any' to serve everyone")
    ap.add_argument("--lease", type=int, default=3600, help="lease seconds (default 3600)")
    ap.add_argument("--seconds", type=int, default=120, help="exit after N seconds (0 = forever)")
    ap.add_argument("--verbose", action="store_true", help="log every packet")
    args = ap.parse_args()

    if args.allow_mac.lower() != "any":
        args.allow_mac = args.allow_mac.lower()

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    try:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_BINDTODEVICE, args.iface.encode() + b"\x00")
    except OSError as exc:
        print(f"afk-dhcp: warning: SO_BINDTODEVICE({args.iface}) failed: {exc}", file=sys.stderr)
    try:
        sock.bind(("", DHCP_SERVER_PORT))
    except PermissionError:
        print("afk-dhcp: error: binding UDP/67 needs root (run with sudo)", file=sys.stderr)
        return 1
    except OSError as exc:
        print(f"afk-dhcp: error: bind UDP/67 failed: {exc}", file=sys.stderr)
        return 1

    log(f"listening on {args.iface} udp/{DHCP_SERVER_PORT}; "
        f"offering {args.client_ip} to {args.allow_mac}, server id {args.host_ip}")
    if args.seconds:
        log(f"will exit after {args.seconds}s")

    deadline = time.monotonic() + args.seconds if args.seconds else None
    served: set[str] = set()
    sock.settimeout(2.0)
    while True:
        if deadline is not None and time.monotonic() >= deadline:
            log("time limit reached; exiting")
            break
        try:
            data, addr = sock.recvfrom(2048)
        except socket.timeout:
            continue
        except KeyboardInterrupt:
            break

        req = parse_packet(data)
        if req is None:
            continue
        if args.allow_mac != "any" and req["mac"] != args.allow_mac:
            log(f"ignoring {req['mac']} (not the gadget device MAC)", args.verbose)
            continue

        mt = req["msg_type"]
        name = {DISCOVER: "DISCOVER", REQUEST: "REQUEST", RELEASE: "RELEASE",
                INFORM: "INFORM", DECLINE: "DECLINE"}.get(mt, f"type{mt}")
        log(f"{name} from {req['mac']} via {addr[0]}:{addr[1]} xid=0x{req['xid']:08x}", args.verbose)

        if mt in (DISCOVER, REQUEST, INFORM):
            reply_type = OFFER if DISCOVER else ACK
            if mt == INFORM:
                reply_type = ACK
            reply = build_reply(req, reply_type, args.client_ip, args.host_ip,
                                args.netmask, args.lease)
            # OFFER needs broadcast; ACK can go to the offered address which is
            # not configured on the client yet, so broadcast is safer on NCM.
            sock.sendto(reply, ("255.255.255.255", DHCP_CLIENT_PORT))
            log(f"sent {'OFFER' if reply_type == OFFER else 'ACK'} {args.client_ip} to {req['mac']}")
            served.add(req["mac"])
        elif mt == RELEASE:
            log(f"RELEASE from {req['mac']}")
        elif mt == DECLINE:
            log(f"DECLINE from {req['mac']} (address conflict?)", False)

    log("done; served clients: " + (", ".join(sorted(served)) if served else "none"))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(0)
