#!/bin/bash
# Video loop player for the Pi fleet. Auto-detects:
#  - board capability tier (Pi 1 = lowres, everything else = hires)
#  - the connected display's aspect ratio (5:4 or 16:9)
# and plays whatever is in the matching /home/admin/Videos_<tier>_<aspect>
# folder, starting from a random rotation offset each boot (e.g. files 1,2,3
# might start at 2 -> 2,3,1,2,3,1,...) but always in the correct relative order.
#
# Single output only. Independent (or mirrored) content across two outputs on
# one board was attempted and reverted - see README's "Known hardware quirk"
# section: a real kernel bug in vc4's HVS channel handling
# (drivers/gpu/drm/vc4/vc4_hvs.c, __vc4_hvs_stop_channel) leaves a second
# simultaneously-active display channel blank regardless of content, on at
# least one Pi 4 (kernel 6.18.34+rpt-rpi-v8). If a future kernel fixes this,
# multi-output support could be revisited (git history has a working
# compositor-based attempt for independent content, and DRM master issues to
# work around for the naive direct-DRM approach).
#
# If more than one display is connected, only the first (sorted) one is used.

sleep 5
rm -f /tmp/mpvsocket-*

MODEL=$(tr -d '\0' < /proc/device-tree/model 2>/dev/null)
case "$MODEL" in
  *"Raspberry Pi 1"*|*"Raspberry Pi Zero"*) TIER="lowres" ;;
  *) TIER="hires" ;;
esac

CONNECTORS=()
for f in /sys/class/drm/card*-*/status; do
  [ -e "$f" ] || continue
  [ "$(cat "$f")" = "connected" ] || continue
  CONNECTORS+=("$(basename "$(dirname "$f")")")   # e.g. card0-HDMI-A-1
done
if [ "${#CONNECTORS[@]}" -gt 1 ]; then
  IFS=$'\n' CONNECTORS=($(sort <<<"${CONNECTORS[*]}")); unset IFS
fi

if [ "${#CONNECTORS[@]}" -eq 0 ]; then
  echo "$(date): no connected displays found" >> /home/admin/videoloop_display.log
  exit 1
fi

base="${CONNECTORS[0]}"
card_num="${base#card}"; card_num="${card_num%%-*}"
conn_name="${base#card${card_num}-}"

MODE=$(head -1 "/sys/class/drm/$base/modes" 2>/dev/null)
ASPECT="5x4"
if [ -n "$MODE" ]; then
  W=${MODE%x*}; H=${MODE#*x}
  IS_WIDE=$(awk "BEGIN{print ($W/$H > 1.4)}" 2>/dev/null)
  [ "$IS_WIDE" = "1" ] && ASPECT="16x9"
fi

VIDEO_DIR="/home/admin/Videos_${TIER}_${ASPECT}"
[ -d "$VIDEO_DIR" ] || VIDEO_DIR="/home/admin/Videos_${TIER}_5x4"
[ -d "$VIDEO_DIR" ] || VIDEO_DIR=$(find /home/admin -maxdepth 1 -type d -name 'Videos_*' | head -1)

if [ "${#CONNECTORS[@]}" -gt 1 ]; then
  echo "$(date): WARNING multiple displays connected (${CONNECTORS[*]}), only using $conn_name" >> /home/admin/videoloop_display.log
fi
echo "$(date): model='$MODEL' tier=$TIER connector=$conn_name mode=$MODE aspect=$ASPECT -> $VIDEO_DIR" >> /home/admin/videoloop_display.log

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

exec mpv --vo=gpu --gpu-context=drm --drm-connector="${conn_name}" \
  --fullscreen --no-terminal --really-quiet \
  --loop-playlist=inf --hwdec=v4l2m2m-copy --no-osc \
  --ao=alsa,null \
  --audio-device="alsa/plughw:CARD=${AUDIO_CARD},DEV=0" \
  --input-ipc-server="/tmp/mpvsocket-${conn_name}" "${ROTATED[@]}"
