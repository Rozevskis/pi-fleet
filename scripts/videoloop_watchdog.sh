#!/bin/bash
# Detects a stalled mpv (time-pos not advancing) on any output and restarts
# the whole player supervisor. Mitigates a known vc4 KMS atomic-commit driver
# bug on older Pi boards that occasionally freezes playback without crashing.
#
# Also detects a GPIO content-jumper change (see videoloop.sh) and restarts
# so it takes effect without needing a reboot - within one poll interval
# (videoloop-watchdog.timer, currently 30s) instead of requiring a manual
# restart. Keep this GPIO-reading logic in sync with videoloop.sh's.
NEEDS_RESTART=0

if command -v gpioget >/dev/null 2>&1 && [ -f /tmp/videoloop_content_state ]; then
  JUMPER_VAL=$(gpioget -c gpiochip0 -b pull-up --numeric 17 2>/dev/null)
  CURRENT_CONTENT="Videos"
  [ "$JUMPER_VAL" = "0" ] && CURRENT_CONTENT="Videos_timelapse"
  RUNNING_CONTENT=$(cat /tmp/videoloop_content_state)
  if [ "$CURRENT_CONTENT" != "$RUNNING_CONTENT" ]; then
    echo "$(date): content jumper changed ($RUNNING_CONTENT -> $CURRENT_CONTENT), restarting" >> /home/admin/videoloop_watchdog.log
    NEEDS_RESTART=1
  fi
fi

STALLED=0

for sock in /tmp/mpvsocket-*; do
  [ -e "$sock" ] || continue
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

if [ "$STALLED" -eq 1 ]; then
  echo "$(date): playback stalled on at least one output, restarting" >> /home/admin/videoloop_watchdog.log
  NEEDS_RESTART=1
fi

if [ "$NEEDS_RESTART" -eq 1 ]; then
  systemctl --user restart videoloop.service
  rm -f /tmp/videoloop_last_pos_*
fi
