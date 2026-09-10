#!/bin/bash
# Flashes the "mother" image onto an SD card: Raspberry Pi OS Lite, cloud-init
# customization (user account, wifi, mpv, our systemd services), and all four
# video-resolution sets so any board can boot with any display and pick the
# right one automatically (see scripts/videoloop.sh).
#
# Usage: sudo bash flash_mother.sh [/dev/sdX]
# If the device isn't given and exactly one USB disk in the 28-256GB range is
# attached, it's used automatically. Otherwise you must specify it explicitly
# (safety: this script will ERASE the target device).
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMG="$REPO/flash/raspios_lite.img.xz"
IMG_URL="https://downloads.raspberrypi.com/raspios_lite_armhf/images/raspios_lite_armhf-2026-06-19/2026-06-18-raspios-trixie-armhf-lite.img.xz"
SHA256="235aae6e32f40eb294b6485f99232d9ea5b6ee0251c8dc40e370177fac4754c2"
VIDEOS_ROOT="$REPO/videos"

MAIN_CHAPTERS_LOWRES_5X4="$VIDEOS_ROOT/lowres_5x4"
MAIN_CHAPTERS_LOWRES_16X9="$VIDEOS_ROOT/lowres_16x9"
MAIN_CHAPTERS_HIRES_5X4="$VIDEOS_ROOT/hires_5x4"
MAIN_CHAPTERS_HIRES_16X9="$VIDEOS_ROOT/hires_16x9"
# Optional: GPIO-jumper-triggered alternate content (see scripts/videoloop.sh).
# Copied only if present - not every checkout will have these.
TIMELAPSE_LOWRES_5X4="$VIDEOS_ROOT/timelapse_lowres_5x4"
TIMELAPSE_LOWRES_16X9="$VIDEOS_ROOT/timelapse_lowres_16x9"
TIMELAPSE_HIRES_5X4="$VIDEOS_ROOT/timelapse_hires_5x4"
TIMELAPSE_HIRES_16X9="$VIDEOS_ROOT/timelapse_hires_16x9"

if [ ! -f "$IMG" ]; then
  echo "=== Downloading Raspberry Pi OS Lite image ==="
  curl -L -o "$IMG" "$IMG_URL"
fi

DEVICE="${1:-}"
if [ -z "$DEVICE" ]; then
  CANDIDATES=()
  for d in /dev/sd?; do
    [ -e "$d" ] || continue
    SIZE=$(lsblk -bno SIZE "$d" 2>/dev/null | head -1)
    TRAN=$(lsblk -no TRAN "$d" 2>/dev/null | head -1)
    if [ "$TRAN" = "usb" ] && [ -n "$SIZE" ] && [ "$SIZE" -ge 28000000000 ] && [ "$SIZE" -le 256000000000 ]; then
      CANDIDATES+=("$d")
    fi
  done
  if [ "${#CANDIDATES[@]}" -eq 1 ]; then
    DEVICE="${CANDIDATES[0]}"
    echo "Auto-detected SD card: $DEVICE"
  else
    echo "Could not auto-detect a single SD card. Found: ${CANDIDATES[*]:-none}"
    echo "Re-run as: sudo bash flash_mother.sh /dev/sdX"
    lsblk -o NAME,SIZE,TYPE,TRAN,RM,MODEL
    exit 1
  fi
fi

SIZE=$(lsblk -bno SIZE "$DEVICE" | head -1)
TRAN=$(lsblk -no TRAN "$DEVICE" | head -1)
echo "=== Target: $DEVICE  Size: $SIZE bytes  Transport: $TRAN ==="
if [ "$TRAN" != "usb" ] || [ "$SIZE" -lt 28000000000 ] || [ "$SIZE" -gt 256000000000 ]; then
  echo "ABORT: $DEVICE doesn't look like a plausible USB SD card (expected 28-256GB)."
  exit 1
fi
read -p "This will ERASE $DEVICE. Type YES to continue: " CONFIRM
[ "$CONFIRM" = "YES" ] || { echo "Aborted."; exit 1; }

echo "=== Unmounting existing partitions ==="
umount "${DEVICE}1" 2>/dev/null || true
umount "${DEVICE}2" 2>/dev/null || true

echo "=== Flashing (this takes a few minutes) ==="
rpi-imager --cli --sha256 "$SHA256" "$IMG" "$DEVICE"

echo "=== Waiting for the card to be readable again ==="
echo "(some USB card readers drop off the bus right after a write - if this"
echo " takes more than ~15s, just reseat the card; the script will pick it"
echo " back up automatically, even if its device letter changes)"
sleep 5   # let a disconnect, if any, actually register before we start checking
ORIGINAL_DEVICE="$DEVICE"
STABLE_COUNT=0
for i in $(seq 1 90); do
  CUR_SIZE=$(lsblk -bno SIZE "$DEVICE" 2>/dev/null | head -1)
  if [ -n "$CUR_SIZE" ] && [ "$CUR_SIZE" != "0" ]; then
    STABLE_COUNT=$((STABLE_COUNT + 1))
    # require two consecutive good reads, 2s apart, so a single stale/transient
    # read right at the disconnect boundary can't fool us into continuing early
    [ "$STABLE_COUNT" -ge 2 ] && break
  else
    STABLE_COUNT=0
  fi
  for d in /dev/sd?; do
    [ -e "$d" ] || continue
    S=$(lsblk -bno SIZE "$d" 2>/dev/null | head -1)
    T=$(lsblk -no TRAN "$d" 2>/dev/null | head -1)
    if [ "$T" = "usb" ] && [ -n "$S" ] && [ "$S" -ge 28000000000 ] && [ "$S" -le 256000000000 ]; then
      DEVICE="$d"
    fi
  done
  sleep 2
done
CUR_SIZE=$(lsblk -bno SIZE "$DEVICE" 2>/dev/null | head -1)
if [ -z "$CUR_SIZE" ] || [ "$CUR_SIZE" = "0" ]; then
  echo "ABORT: card never came back online. Reseat it and re-run:"
  echo "  sudo bash flash_mother.sh"
  exit 1
fi
if [ "$DEVICE" != "$ORIGINAL_DEVICE" ]; then
  echo "Card reappeared at $DEVICE (was $ORIGINAL_DEVICE) - continuing with the new path."
fi

echo "=== Re-reading partition table ==="
partprobe "$DEVICE" || true
udevadm settle
sleep 3

echo "=== Growing rootfs partition to fill the card ==="
parted -s "$DEVICE" resizepart 2 100%
partprobe "$DEVICE" || true
udevadm settle
sleep 2
e2fsck -f -y "${DEVICE}2" || true
resize2fs "${DEVICE}2"

BOOT_PART="${DEVICE}1"
ROOT_PART="${DEVICE}2"

BOOT_MNT=$(lsblk -no MOUNTPOINT "$BOOT_PART" | head -1)
if [ -z "$BOOT_MNT" ]; then
  mkdir -p /mnt/mother_boot
  mount "$BOOT_PART" /mnt/mother_boot
  BOOT_MNT=/mnt/mother_boot
fi
ROOT_MNT=$(lsblk -no MOUNTPOINT "$ROOT_PART" | head -1)
if [ -z "$ROOT_MNT" ]; then
  mkdir -p /mnt/mother_root
  mount "$ROOT_PART" /mnt/mother_root
  ROOT_MNT=/mnt/mother_root
fi
echo "Boot: $BOOT_MNT   Root: $ROOT_MNT"

echo "=== Clearing any pre-baked cloud-init cache (known issue: the stock image"
echo "    ships with a stale 'already initialized' marker from RPi's own build) ==="
rm -rf "$ROOT_MNT/var/lib/cloud/instances" "$ROOT_MNT/var/lib/cloud/data" "$ROOT_MNT/var/lib/cloud/sem"

echo "=== Writing cloud-init config ==="
cp -f "$REPO/cloud-init/user-data" "$BOOT_MNT/user-data"
cp -f "$REPO/cloud-init/meta-data" "$BOOT_MNT/meta-data"
cp -f "$REPO/cloud-init/network-config" "$BOOT_MNT/network-config"

if ! grep -q gpu_mem "$BOOT_MNT/config.txt"; then
  {
    echo ""
    echo "# Reserve enough GPU mem for hardware video decode alongside a lean OS"
    echo "gpu_mem=128"
  } >> "$BOOT_MNT/config.txt"
fi

echo "=== Copying all four video sets (3 main chapters each) ==="
copy_set() {
  local src="$1" dest_name="$2"
  if [ ! -d "$src" ] || [ -z "$(ls -A "$src"/*.mp4 2>/dev/null)" ]; then
    echo "  (skipping $dest_name - no video files at $src)"
    return
  fi
  local dest="$ROOT_MNT/home/admin/$dest_name"
  mkdir -p "$dest"
  cp -v "$src"/*.mp4 "$dest/"
}
copy_set "$MAIN_CHAPTERS_LOWRES_5X4" "Videos_lowres_5x4"
copy_set "$MAIN_CHAPTERS_LOWRES_16X9" "Videos_lowres_16x9"
copy_set "$MAIN_CHAPTERS_HIRES_5X4" "Videos_hires_5x4"
copy_set "$MAIN_CHAPTERS_HIRES_16X9" "Videos_hires_16x9"
copy_set "$TIMELAPSE_LOWRES_5X4" "Videos_timelapse_lowres_5x4"
copy_set "$TIMELAPSE_LOWRES_16X9" "Videos_timelapse_lowres_16x9"
copy_set "$TIMELAPSE_HIRES_5X4" "Videos_timelapse_hires_5x4"
copy_set "$TIMELAPSE_HIRES_16X9" "Videos_timelapse_hires_16x9"

chown -R 1000:1000 "$ROOT_MNT/home/admin"

echo "=== Syncing and unmounting ==="
sync
umount "$BOOT_MNT" || umount -l "$BOOT_MNT"
umount "$ROOT_MNT" || umount -l "$ROOT_MNT"
[ -d /mnt/mother_boot ] && rmdir /mnt/mother_boot 2>/dev/null || true
[ -d /mnt/mother_root ] && rmdir /mnt/mother_root 2>/dev/null || true

echo ""
echo "=== DONE ==="
echo "Card is ready for ANY board in the fleet (Pi 1/3/4) and ANY display"
echo "(5:4 or 16:9) - it self-configures on boot."
echo "Login: admin / e4LabPASS"
echo "SSH: ssh admin@pi-<serial>.local  (hostname = pi- + the board's own CPU serial)"
