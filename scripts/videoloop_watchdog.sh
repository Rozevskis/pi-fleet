#!/bin/bash
# Detects a stalled mpv (time-pos not advancing) on any output and restarts
# the whole player supervisor. Mitigates a known vc4 KMS atomic-commit driver
# bug on older Pi boards that occasionally freezes playback without crashing.
STALLED=0
FOUND_ANY=0

for sock in /tmp/mpvsocket-*; do
  [ -e "$sock" ] || continue
  FOUND_ANY=1
  STATE_FILE="/tmp/videoloop_last_pos_$(basename "$sock")"
  CURRENT=$(python3 -c "
import socket, json
try:
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(2)
    s.connect('$sock')
    s.sendall(json.dumps({'command':['get_property','time-pos']}).encode()+b'\n')
    resp = json.loads(s.recv(4096).decode().splitlines()[0])
    print(resp.get('data',''))
except Exception:
    print('ERROR')
")
  if [ "$CURRENT" = "ERROR" ] || [ -z "$CURRENT" ]; then
    continue
  fi
  if [ -f "$STATE_FILE" ]; then
    LAST=$(cat "$STATE_FILE")
    [ "$LAST" = "$CURRENT" ] && STALLED=1
  fi
  echo "$CURRENT" > "$STATE_FILE"
done

if [ "$FOUND_ANY" -eq 0 ]; then
  exit 0
fi

if [ "$STALLED" -eq 1 ]; then
  echo "$(date): playback stalled on at least one output, restarting" >> /home/admin/videoloop_watchdog.log
  systemctl --user restart videoloop.service
  rm -f /tmp/videoloop_last_pos_*
fi
