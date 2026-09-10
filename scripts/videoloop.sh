#!/bin/bash
# Video loop player for the Pi fleet. Auto-detects:
#  - board capability tier (Pi 1 = lowres, everything else = hires)
#  - EVERY connected display, each classified 5:4 or 16:9 by its own mode
# and, for each connected display, launches an independent mpv instance bound
# to that specific output, playing the matching /home/admin/Videos_<tier>_<aspect>
# folder. Boards with a single display behave exactly as before; boards with
# two (e.g. Pi 4's dual HDMI) show independent content on each screen.
#
# Rotation: each output starts from a random offset into its own sorted file
# list each boot (e.g. files 1,2,3 might start at 2 -> 2,3,1,2,3,1,...) but
# always plays in the correct relative order.
#
# Audio: a single-output board uses the aux/headphone jack (matches the rest
# of the fleet). A multi-output board can't share one jack between two
# different videos, so each screen's audio goes out THAT screen's own HDMI
# port, paired with connectors by sort order. This pairing is a best-effort
# default - verify with `aplay -l` and this script's own log
# (~/videoloop_display.log) on real hardware and adjust if a board's HDMI
# audio cards don't enumerate in the same order as its DRM connectors.

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

mapfile -t HDMI_AUDIO_CARDS < <(aplay -l | grep -i hdmi | sed -n 's/^card [0-9]\+: \([^ ]*\).*/\1/p')
AUX_CARD=$(aplay -l | grep -i headphone | head -1 | sed -n 's/^card [0-9]\+: \([^ ]*\).*/\1/p')

PIDS=()
for i in "${!CONNECTORS[@]}"; do
  base="${CONNECTORS[$i]}"
  card_num="${base#card}"; card_num="${card_num%%-*}"
  conn_name="${base#card${card_num}-}"

  d="/sys/class/drm/$base"
  MODE=$(head -1 "$d/modes" 2>/dev/null)
  ASPECT="5x4"
  if [ -n "$MODE" ]; then
    W=${MODE%x*}; H=${MODE#*x}
    IS_WIDE=$(awk "BEGIN{print ($W/$H > 1.4)}" 2>/dev/null)
    [ "$IS_WIDE" = "1" ] && ASPECT="16x9"
  fi

  VIDEO_DIR="/home/admin/Videos_${TIER}_${ASPECT}"
  [ -d "$VIDEO_DIR" ] || VIDEO_DIR="/home/admin/Videos_${TIER}_5x4"
  [ -d "$VIDEO_DIR" ] || VIDEO_DIR=$(find /home/admin -maxdepth 1 -type d -name 'Videos_*' | head -1)

  echo "$(date): model='$MODEL' tier=$TIER connector=$conn_name mode=$MODE aspect=$ASPECT -> $VIDEO_DIR" >> /home/admin/videoloop_display.log

  ( cd "$VIDEO_DIR" || exit 1
    mapfile -t FILES < <(ls *.mp4 2>/dev/null | sort)
    N=${#FILES[@]}
    [ "$N" -eq 0 ] && exit 1
    OFFSET=$((RANDOM % N))
    ROTATED=("${FILES[@]:$OFFSET}" "${FILES[@]:0:$OFFSET}")

    if [ "${#CONNECTORS[@]}" -gt 1 ]; then
      AUDIO_CARD="${HDMI_AUDIO_CARDS[$i]:-${HDMI_AUDIO_CARDS[0]:-$AUX_CARD}}"
    else
      AUDIO_CARD="$AUX_CARD"
      [ -z "$AUDIO_CARD" ] && AUDIO_CARD="${HDMI_AUDIO_CARDS[0]:-}"
    fi

    # Note: mpv's own internal DRM card index (used in --drm-connector) does
    # NOT necessarily match the sysfs card number in $card_num - on a Pi 4
    # it enumerated as mpv's "card 0" while sysfs called it "card1". A bare
    # connector name (no card prefix) resolves correctly as long as there's
    # only one usable GPU, which is the case on every board in this fleet.
    exec mpv --vo=gpu --gpu-context=drm --drm-connector="${conn_name}" \
      --fullscreen --no-terminal --really-quiet \
      --loop-playlist=inf --hwdec=v4l2m2m-copy --no-osc \
      --ao=alsa,null \
      --audio-device="alsa/plughw:CARD=${AUDIO_CARD},DEV=0" \
      --input-ipc-server="/tmp/mpvsocket-${conn_name}" "${ROTATED[@]}"
  ) &
  PIDS+=("$!")
done

if [ "${#PIDS[@]}" -eq 0 ]; then
  exit 1
fi

# If any one output's player dies, exit so systemd restarts the whole
# supervisor - keeps crash recovery simple and consistent for both
# single- and multi-output boards.
wait -n "${PIDS[@]}"
exit $?
