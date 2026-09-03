#!/usr/bin/env python3
import socket, sys, json

CMDS = {
    "next": {"command": ["playlist-next"]},
    "prev": {"command": ["playlist-prev"]},
    "pause": {"command": ["cycle", "pause"]},
    "restart": {"command": ["seek", 0, "absolute"]},
    "unpause": {"command": ["set_property", "pause", False]},
}

if len(sys.argv) != 2 or sys.argv[1] not in CMDS:
    print("usage: mpvctl.py next|prev|pause|restart|unpause")
    sys.exit(1)

s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect("/tmp/mpvsocket")
s.sendall((json.dumps(CMDS[sys.argv[1]]) + "\n").encode())
s.settimeout(1)
try:
    print(s.recv(4096).decode().strip())
except socket.timeout:
    pass
