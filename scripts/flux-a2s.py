#!/usr/bin/env python3
"""How many players are connected, asked of the server itself over Steam's A2S_INFO.

    flux-a2s [port] [host]      prints the player count, e.g. "3"

Enshrouded has no RCON and no admin console, so the server's Steam query port is the only thing
inside the container that knows who is online. The games hub reads the same answer from outside
on the same port (games-website src/games/enshrouded/server.js).

Exit status: 0 with the count printed, 1 when nothing answered (the world is still loading, or
the server is hung), 2 when something answered that is not an A2S_INFO reply. The scheduler
treats 1 and 2 the same way: the count is unknown.
"""
import socket
import sys

REQUEST = b"\xff\xff\xff\xffTSource Engine Query\x00"
TIMEOUT = 3.0


def _cstring(data, at):
    end = data.index(b"\x00", at)
    return end + 1


def parse_info(data):
    """An A2S_INFO reply (without the 4-byte header) -> the player count. ValueError otherwise."""
    if len(data) < 2 or data[0] != 0x49:
        raise ValueError("not an A2S_INFO reply")
    at = 2  # header byte, protocol byte
    for _ in range(4):  # name, map, folder, game
        at = _cstring(data, at)
    at += 2  # Steam app id (short)
    if len(data) < at + 1:
        raise ValueError("reply too short")
    return data[at]


def query(host, port):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(TIMEOUT)
    try:
        request = REQUEST
        # One challenge round at most: servers since 2020 answer the first request with 0x41 and
        # a 4-byte challenge that the second request must repeat.
        for _ in range(2):
            sock.sendto(request, (host, port))
            data, _ = sock.recvfrom(4096)
            if data[:4] != b"\xff\xff\xff\xff":
                raise ValueError("split or malformed reply")
            body = data[4:]
            if body[:1] == b"\x41" and len(body) >= 5:
                request = REQUEST + body[1:5]
                continue
            return parse_info(body)
        raise ValueError("challenged twice")
    finally:
        sock.close()


def main(argv):
    port = int(argv[1]) if len(argv) > 1 else 15637
    host = argv[2] if len(argv) > 2 else "127.0.0.1"
    try:
        print(query(host, port))
        return 0
    except (socket.timeout, ConnectionError, OSError):
        return 1
    except (ValueError, IndexError):
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
