#!/usr/bin/env python3
import socket, sys, json, glob

CMDS = {
    "next": {"command": ["playlist-next"]},
    "prev": {"command": ["playlist-prev"]},
    "pause": {"command": ["cycle", "pause"]},
    "restart": {"command": ["seek", 0, "absolute"]},
    "unpause": {"command": ["set_property", "pause", False]},
}


def usage():
    print("usage: mpvctl.py next|prev|pause|restart|unpause [socket-path]")
    print("       with no socket given, targets every /tmp/mpvsocket-* (all connected outputs)")
    sys.exit(1)


if len(sys.argv) not in (2, 3) or sys.argv[1] not in CMDS:
    usage()

targets = [sys.argv[2]] if len(sys.argv) == 3 else sorted(glob.glob("/tmp/mpvsocket-*"))
if not targets:
    print("no mpv sockets found under /tmp/mpvsocket-*")
    sys.exit(1)

for path in targets:
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(1)
        s.connect(path)
        s.sendall((json.dumps(CMDS[sys.argv[1]]) + "\n").encode())
        print(path, "->", s.recv(4096).decode().strip())
    except Exception as e:
        print(path, "-> ERROR", e)
