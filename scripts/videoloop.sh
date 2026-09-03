#!/bin/bash
# Video loop player for the Pi fleet. Auto-detects:
#  - board capability tier (Pi 1 = lowres, everything else = hires)
#  - connected display aspect ratio (5:4 vs 16:9)
# and picks the matching /home/admin/Videos_<tier>_<aspect> folder.
# Plays files in that folder in sorted order, starting from a random
# rotation offset each boot (so e.g. 1,2,3 becomes 2,3,1,2,3,1,... but
# never out of sequence).

sleep 5
rm -f /tmp/mpvsocket

MODEL=$(tr -d '\0' < /proc/device-tree/model 2>/dev/null)
case "$MODEL" in
  *"Raspberry Pi 1"*|*"Raspberry Pi Zero"*) TIER="lowres" ;;
  *) TIER="hires" ;;
esac

MODE=""
for f in /sys/class/drm/card*-*/status; do
  if [ -e "$f" ] && [ "$(cat "$f")" = "connected" ]; then
    d=$(dirname "$f")
    MODE=$(head -1 "$d/modes" 2>/dev/null)
    break
  fi
done

ASPECT="5x4"
if [ -n "$MODE" ]; then
  W=${MODE%x*}
  H=${MODE#*x}
  IS_WIDE=$(awk "BEGIN{print ($W/$H > 1.4)}" 2>/dev/null)
  [ "$IS_WIDE" = "1" ] && ASPECT="16x9"
fi

VIDEO_DIR="/home/admin/Videos_${TIER}_${ASPECT}"
echo "$(date): model='$MODEL' tier=$TIER mode=$MODE aspect=$ASPECT -> $VIDEO_DIR" >> /home/admin/videoloop_display.log

# Fall back to the 5:4 set of the same tier if the exact aspect folder is missing,
# and fall back across tiers as a last resort so it always plays something.
if [ ! -d "$VIDEO_DIR" ]; then
  VIDEO_DIR="/home/admin/Videos_${TIER}_5x4"
fi
if [ ! -d "$VIDEO_DIR" ]; then
  VIDEO_DIR=$(find /home/admin -maxdepth 1 -type d -name 'Videos_*' | head -1)
fi

cd "$VIDEO_DIR" || exit 1
mapfile -t FILES < <(ls *.mp4 2>/dev/null | sort)
N=${#FILES[@]}
if [ "$N" -eq 0 ]; then
  echo "no videos found in $VIDEO_DIR" >&2
  exit 1
fi
OFFSET=$((RANDOM % N))
ROTATED=("${FILES[@]:$OFFSET}" "${FILES[@]:0:$OFFSET}")

# Prefer the aux/headphone jack; fall back to HDMI audio if no headphone device exists.
AUDIO_CARD=$(aplay -l | grep -i headphone | head -1 | sed -n 's/^card [0-9]\+: \([^ ]*\).*/\1/p')
if [ -z "$AUDIO_CARD" ]; then
  AUDIO_CARD=$(aplay -l | grep -i hdmi | head -1 | sed -n 's/^card [0-9]\+: \([^ ]*\).*/\1/p')
fi

exec mpv --vo=gpu --gpu-context=drm --fullscreen --no-terminal --really-quiet \
  --loop-playlist=inf --hwdec=v4l2m2m-copy --no-osc \
  --audio-device="alsa/plughw:CARD=${AUDIO_CARD},DEV=0" \
  --input-ipc-server=/tmp/mpvsocket "${ROTATED[@]}"
