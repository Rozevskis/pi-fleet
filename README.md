# Pi video-loop fleet

One "mother" SD card image that works across the whole fleet (Pi 1, Pi 3, Pi 4 x2)
and any attached display (5:4 or 16:9). Each board auto-detects its own capability
tier and the connected screen's aspect ratio at boot, and plays the matching video
set — no per-board configuration needed. Cards are fully interchangeable between
boards and displays.

## How the auto-detection works

`scripts/videoloop.sh` runs on every boot:
1. Reads `/proc/device-tree/model` to classify the board as `lowres` tier
   (Pi 1 / Pi Zero — weak decode, needs small files) or `hires` tier (everything
   else — Pi 3/4 can handle full 1280x1024 / 1920x1080 H.264).
2. Reads the connected DRM display's preferred mode from
   `/sys/class/drm/card*-*/status` + `modes` to classify it as `5x4` or `16x9`.
3. For EACH connected display independently, plays whatever is in
   `/home/admin/Videos_<tier>_<aspect>/` (own mpv instance bound to that
   output via `--drm-connector`), starting from a
   random rotation offset each boot (e.g. files 1,2,3 might start at 2 → 2,3,1,2,3,1,...)
   but always in the correct relative order.

Video resolutions used per tier:
- `lowres` (Pi 1): 640x512 (5:4) / 640x360 (16:9)
- `hires` (Pi 3/4): 1280x1024 (5:4) / 1920x1080 (16:9)

### Multiple displays (e.g. Pi 4's dual HDMI)

A board with more than one display connected gets one independent `mpv`
instance per output, each bound to its specific connector
(`--drm-connector=<card>.<connector>`), each auto-detecting *that screen's*
own aspect ratio and playing its own random-start rotation of the matching
video set — genuinely different content per screen, not mirrored.

If any one output's player dies or stalls, the whole board's playback
restarts together (all outputs) rather than trying to recover just the one —
simpler, and consistent with how single-output boards already recover.

**Audio on multi-output boards**: a single-output board uses the aux jack, but
two different videos can't sensibly share one audio jack. So on a
multi-display board, each screen's audio comes out *that screen's own* HDMI
port, paired with connectors by sort order (first connector ↔ first HDMI audio
card, etc). This pairing is a best-effort default — verify against
`~/videoloop_display.log` and `aplay -l` on real hardware, since it hasn't
been confirmed against every board/connector-naming combination yet.

Audio on single-output boards still defaults to the aux/headphone jack,
falling back to HDMI if no headphone device is found.

## Repo layout

- `cloud-init/` — `meta-data`, `network-config` (tracked), `user-data` (generated,
  gitignored — see below)
- `scripts/` — the actual player, IPC control, and stall-watchdog scripts. Edit
  these, not `user-data` directly.
- `systemd/` — the user-level systemd units for the player and watchdog.
- `videos/` — the four resolution/aspect video sets (gitignored content,
  tracked folder structure via `.gitkeep`). Populate with the 3 main-chapter
  clips per tier/aspect; see naming in `flash_mother.sh`.
- `flash/` — `flash_mother.sh` (does the actual flashing) and
  `build_user_data.py` (assembles `cloud-init/user-data` from `scripts/` +
  `systemd/`).

## Making a change

1. Edit whatever needs changing in `scripts/` or `systemd/`.
2. Regenerate the cloud-init config:
   ```
   python3 flash/build_user_data.py
   ```
3. Re-flash a card (see below), or `scp` the changed file directly to an
   already-running Pi and `systemctl --user restart videoloop.service`.

## Flashing a card

```
sudo bash flash/flash_mother.sh [/dev/sdX]
```

Auto-detects the SD card if exactly one plausible USB disk (28-256GB) is
attached; otherwise pass the device explicitly. This will ERASE the target
device — the script requires typing `YES` to confirm.

The script downloads `raspios_lite.img.xz` on first run if not already present
(cached in `flash/`, gitignored), flashes it, grows the root partition to fill
the card, clears a known stale cloud-init cache baked into the stock image,
writes the cloud-init config, and copies all four video sets from `videos/`
onto the card.

## Known hardware quirk

Older Pi boards (confirmed on a Pi 1) have a vc4 KMS driver bug that
occasionally freezes video playback (`Failed to commit atomic request: Error
number 22`) without crashing the process. `videoloop-watchdog.timer` checks
every 30s whether `mpv`'s playback position is actually advancing and restarts
it if not — this is a mitigation, not a fix (no software fix found; `vo=gpu`
was the most stable option tried, more so than `vo=gpu-next` or `vo=drm`,
which hit the same bug faster/immediately).

## Access

- SSH: `ssh admin@pi-<serial>.local` (hostname is `pi-` + the board's own CPU
  serial, set at first boot — unique per physical board regardless of which
  card is inserted)
- Login: `admin` / `e4LabPASS`
- Player control: `~/mpvctl.py next|prev|pause|restart|unpause` over SSH —
  with no extra arg this targets every connected output at once; pass a
  specific `/tmp/mpvsocket-<connector>` path as a second arg to control just
  one screen on a multi-display board
