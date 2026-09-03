#!/bin/bash
# Detects a stalled mpv (time-pos not advancing) and restarts the player.
# Mitigates a known vc4 KMS atomic-commit driver bug on older Pi boards that
# occasionally freezes playback without crashing the process.
STATE_FILE=/tmp/videoloop_last_pos
CURRENT=$(python3 -c "
import socket, json
try:
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(2)
    s.connect('/tmp/mpvsocket')
    s.sendall(json.dumps({'command':['get_property','time-pos']}).encode()+b'\n')
    resp = json.loads(s.recv(4096).decode().splitlines()[0])
    print(resp.get('data',''))
except Exception:
    print('ERROR')
")

if [ "$CURRENT" = "ERROR" ] || [ -z "$CURRENT" ]; then
  exit 0
fi

if [ -f "$STATE_FILE" ]; then
  LAST=$(cat "$STATE_FILE")
  if [ "$LAST" = "$CURRENT" ]; then
    echo "$(date): playback stalled at $CURRENT, restarting" >> /home/admin/videoloop_watchdog.log
    systemctl --user restart videoloop.service
    rm -f "$STATE_FILE"
    exit 0
  fi
fi
echo "$CURRENT" > "$STATE_FILE"
