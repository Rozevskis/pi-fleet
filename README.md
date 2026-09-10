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
3. Plays whatever is in `/home/admin/Videos_<tier>_<aspect>/`, starting from a
   random rotation offset each boot (e.g. files 1,2,3 might start at 2 → 2,3,1,2,3,1,...)
   but always in the correct relative order.

Video resolutions used per tier:
- `lowres` (Pi 1): 640x512 (5:4) / 640x360 (16:9)
- `hires` (Pi 3/4): 1280x1024 (5:4) / 1920x1080 (16:9)

Audio defaults to the aux/headphone jack, falling back to HDMI if no headphone
device is found.

### Multiple displays on one board (e.g. Pi 4's dual HDMI)

Single output only, currently. If more than one display is connected, only
the first (sorted) connector is used - see "Known hardware quirk" below for
why independent (or mirrored) content across both outputs isn't supported
right now, even though it was implemented and tested. A specific board can
override which connector is used by creating `~/.videoloop_connector`
containing the connector name (e.g. `HDMI-A-2`).

### GPIO content switch (kombucha vs. timelapse)

A board can be wired with a jumper across **GPIO17 (physical pin 11) and a
ground pin**. If bridged at boot, `videoloop.sh` plays
`Videos_timelapse_<tier>_<aspect>` instead of the default
`Videos_<tier>_<aspect>` - e.g. for showing the Irbe camera timelapses
instead of the usual kombucha content on one specific board. No jumper (the
normal case for every other board) behaves exactly as before. Reading the
pin requires the `gpiod` package (for `gpioget`); if it's missing, or the pin
can't be read for any reason, this fails safe back to the default content
rather than blocking playback.

Note: `gpioget` syntax here is for **libgpiod v2** (`-c`/`-b`/`--numeric`
flags) - the CLI changed significantly from v1, which used positional
arguments instead.

**Hot-swap**: moving the jumper takes effect without a reboot.
`videoloop-watchdog.timer` (already polling every 30s for stalled playback)
also re-reads the pin each cycle and restarts the player if the jumper state
no longer matches what's currently playing - so a change takes effect within
about 30 seconds, with a brief restart blip when it switches.

## Repo layout

- `cloud-init/` — `meta-data`, `network-config` (tracked), `user-data` (generated,
  gitignored — see below)
- `scripts/` — the actual player, IPC control, and stall-watchdog scripts. Edit
  these, not `user-data` directly.
- `systemd/` — the user-level systemd units for the player and watchdog.
- `videos/` — the four resolution/aspect video sets (gitignored content,
  tracked folder structure via `.gitkeep`). Populate with the 3 main-chapter
  clips per tier/aspect; see naming in `flash_mother.sh`. Also holds the
  optional `timelapse_{lowres,hires}_{5x4,16x9}` folders (four combinations)
  for the GPIO-switched alternate content (see above) - these are copied to
  the card only if present, so a checkout without them still works fine.
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

## Known hardware quirks

**Occasional playback freeze** (seen on a Pi 1): older Pi boards have a vc4
KMS driver bug that occasionally freezes video playback (`Failed to commit
atomic request: Error number 22`) without crashing the process.
`videoloop-watchdog.timer` checks every 30s whether `mpv`'s playback position
is actually advancing and restarts it if not — this is a mitigation, not a
fix (no software fix found; `vo=gpu` was the most stable option tried, more
so than `vo=gpu-next` or `vo=drm`, which hit the same bug faster/immediately).

**Dual-output boards can't show independent (or mirrored) content per screen**
(seen on a Pi 4 with two HDMI monitors): only one process can hold DRM master
per GPU device, so two independent `mpv` processes (one per connector) can't
both drive the display directly - the second fails with "Permission denied"
acquiring master. Routing both through a `labwc` compositor (so one process
holds master, hosting two Wayland clients each pinned to its own output via
window rules) gets past *that* problem, but hits a real kernel bug instead: a
second simultaneously-active display channel stays blank regardless of
content (mirrored or independent), because of a `WARNING` in the vc4 driver's
Hardware Video Scaler channel handling
(`drivers/gpu/drm/vc4/vc4_hvs.c:1064`, `__vc4_hvs_stop_channel`) on kernel
`6.18.34+rpt-rpi-v8`. This is a kernel/firmware bug, not fixable from
userspace. `scripts/videoloop.sh` therefore only ever uses the first detected
display; the compositor-based attempt (git history around the commits
touching multi-display support) is left as a reference in case a future
kernel release fixes the underlying HVS bug and this is worth revisiting.

## Access

- SSH: `ssh admin@pi-<serial>.local` (hostname is `pi-` + the board's own CPU
  serial, set at first boot — unique per physical board regardless of which
  card is inserted)
- Login: `admin` / `e4LabPASS`
- Player control: `~/mpvctl.py next|prev|pause|restart|unpause` over SSH
