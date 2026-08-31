# PDK games lose graphics (audio still plays) — caused by the shim's `jail_pdk.conf` patch

**Status:** **FIXED and confirmed on hardware 2026-08-31.** Cause isolated by the TLS-project agent;
findings revised, fix built, installed on the Go and verified by the device owner the same day.
**Verdict:** the regression is **ours — `bluetooth-shim` 1.1.0**. Not the TLS updates
(`OpenSSL-legacyWebOS`), not LunaCE, not `usb-settings`.
**Fix:** shipped as `org.webosarchive.btgamepad` **1.2.0**, TouchPad Go only. Verified end to end
through a real **Preware upgrade over 1.1.0** on the Go (2026-08-31): the device was deliberately
reverted to a genuine 1.1.0 state — registry, payload, control scripts and the bind-mounted
`jail_pdk.conf` — and the feed upgrade repaired it. No uninstall required.

---

## Symptom

PDK ("Linux binary") games start — the process runs, audio works — but **nothing reaches the
screen**, and the UI freezes. Reported against `Snes9x EX` and `Flight Control`, both of which
worked before the shim / USB / TLS work was installed. Reproduced with `Snes9x EX`
(`com.explusalpha.snes9x`), and previously with `Clone Keen` and `Emu7800` on the same device.

The app itself is healthy — it is not failing to render. Clone Keen's own log on this device:

```
Starting graphics driver...
VidDrv_SetFullscreen: webOS 1024x768 fullscreen, game surface 320x240
Creating ScrollSurface (512x512)
SoundDrv_Start(): SDL sound system initilized.
```

It detects the panel correctly, creates its surfaces, maps `libEGL`/`libpvrtc`/`libSDL`, and opens
the jail's `/dev/fb1`. The picture is drawn; it is never composited to the screen.

---

## Cause

`bluetooth-shim` 1.1.0 (`postinst` step 3, and `scripts/deploy.sh --setup`) patches
`/etc/jail_pdk.conf`, inserting two lines immediately after `mkdir /dev`:

```
mkdir /dev
+mkdir /dev/input
+mount ro /dev/input
copynod /dev/urandom
...
copynod /dev/fb0
copynod /dev/fb1
copynod /dev/kgsl-2d0 / kgsl-2d1 / kgsl-3d0
copynod /dev/pmem_smipool / pmem_adsp
```

Removing those two lines restores graphics. Re-adding them breaks it again.

---

## Evidence (A/B, both directions)

Identical procedure for every run, to keep it single-variable:

1. close the app, `umount` every `/var/palm/jail/<app>/*` mount, `rm -rf` the jail dir
2. swap `/etc/jail_pdk.conf`
3. restart Luna (`stop LunaSysMgr; sleep 4; start LunaSysMgr`)
4. **verify `applicationManager` answers before launching** (see Gotchas)
5. launch `com.explusalpha.snes9x` via `applicationManager/launch`

| `/etc/jail_pdk.conf` | size | `/dev/input` lines | result |
|---|---|---|---|
| stock (`.btshim-orig`) | 3977 B | 0 | app runs, **one** `fb1` handle, UI stays responsive, **graphics visible (confirmed by the device owner)** |
| shim-patched | 4014 B | 2 | app runs, **two** `fb1` handles, `applicationManager` goes silent — **UI frozen** |

Everything else was held constant across both runs and verified in place: TLS stack installed with
its launcher patch (3 lines) and all three env-scrub wrappers, `usbctl-watchd` running, the shim's
`libpmbtgamepad.so` still preloaded into `BluetoothMonitor`, stock LunaSysMgr `9a5c1c37…`.

### Ruled out beforehand (separate A/B matrix, same device, 2026-08-29)

The same audio-only/freeze symptom persisted with **every one of these removed**, which is why the
TLS project was cleared:

| removed | still broken? |
|---|---|
| luna-tls13 launcher env (stock `/etc/event.d/LunaSysMgr`, verified `LD_PRELOAD` = ptmalloc3+memcpy only) | yes |
| all three TLS env-scrub wrappers (stock `setcpushares-pdk` 555 B, `setcpushares-task` 619 B, `media-pipeline` 1741704 B) | yes |
| LunaCE (stock webOS 3.0.5 `LunaSysMgr`) | yes |
| Atlas browser (upstart job parked, engine killed, cryptofs verified healthy) | yes |

The PDK child process was verified clean in every run: `ssl11 maps: 0`, environment exactly
`LD_PRELOAD=libpvrtc.so` + the app-dir `LD_LIBRARY_PATH` — i.e. byte-identical to what stock webOS
gives it. The `jail_pdk.conf` patch was live throughout that matrix and was never tested, which is
why nothing moved the needle.

---

## Mechanism — corrected 2026-08-31

An earlier revision of this document claimed jailer's `mount` verb "creates a fresh, empty tmpfs"
rather than bind-mounting, and that the host's `/dev/input` was legitimately empty. **Both were
wrong, and they were the two facts that made the patch look harmless.** What is actually true:

### `mount <ro|rw> <path>` is a real bind mount

The verb is `mount [ro|rw] <path>`; jailer bind-mounts the host's `<path>` onto the same path inside
the jail (`LunaJail::CJail::mountDirectory`). It has to be — the same verb is how the jail gets
`/lib`, `/bin`, `/usr/lib` and `/usr/share`, which obviously contain the host's files.

The `/proc/mounts` line that prompted the tmpfs reading —

```
tmpfs /var/palm/jail/com.explusalpha.snes9x/dev/input tmpfs rw,relatime,size=2048k,mode=755 0 0
```

— is reporting the **source** superblock, exactly as it does for every other bind mount in the jail
(`/lib` shows `/dev/mapper/store-root … ext3`). The host's `/dev` *is* a 2048k tmpfs:

```
tmpfs /dev tmpfs rw,relatime,size=2048k,mode=755 0 0
```

so a bind of `/dev/input` reports precisely that superblock, `rw` flags and all. `/dev/snd` and
`/dev/shm` report the same line for the same reason — they are also under `/dev`. The `ro` in the
config is a per-mount flag and does not show in this kernel's `/proc/mounts`.

### So the patch hands a jail a live handle on the device's real `/dev/input`

That is destructive, and the damage is on this device right now. `/dev/input` on the Go:

```
dr-xr-xr-x  2 5241  jailuser  40  Aug 31 07:09 .
```

Owned by **uid 5241**, which `/var/palm/data/jailusers` identifies as the jail user for
`com.explusalpha.snes9x`, mode `0555`, and **empty** — while the kernel still has all three input
devices registered:

```
/proc/bus/input/devices:  gpio-keys (event0), pmic8058_pwrkey (event1), headset (event2)
/sys/class/input/event0 -> 13:64   event1 -> 13:65   event2 -> 13:66
```

and their consumers are holding the destroyed inodes open:

```
hidd         /proc/1937  /dev/input/event0 (deleted)
hidd         /proc/1937  /dev/input/event1 (deleted)
hidd         /proc/1937  /dev/input/event2 (deleted)
PmWsfDaemon  /proc/1970  /dev/input/event0 (deleted)
```

Something walked through the bind mount and deleted the device's real input nodes — the home/volume
keys, the power key and the headset key — leaving `hidd` running on inodes with no directory entry.

**It does not take an `rm -rf`.** An earlier revision of this section guessed the tester's `rm -rf`
was the culprit; that was wrong. Measured on the Go 2026-08-31 — a *single* `jailer -t pdk` run with
the 1.1.0 config, no game launch, no delete:

```
before:  drwxr-xr-x  2 root  root       /dev/input
after:   dr-xr-xr-x  2 6037  jailuser   /dev/input      <-- the host's, chowned to the jail user
```

jailer's `mkdir /dev/input` verb chowns and chmods its argument. On the second and every later launch
the mount is already up (`Skipping mount …: already mounted`), so the `mkdir` lands on the **mounted**
directory — i.e. the host's `/dev`. `jailer -N` teardown is still safe (it unmounts first), but the
damage happens during ordinary jail *setup*, on every launch, with nobody doing anything unusual.

Note what this does to the earlier conclusion "the host's `/dev/input` is empty, so the patch
delivers zero gamepad nodes while still breaking graphics": the directory is empty **because of the
patch**, not independently of it. On a healthy Go it contains `event0`–`event2`, and a connected pad
lands at `event3`. The bind mount did deliver the pad — that is why bringup worked.

### Why the Go and not the big TouchPad — measured 2026-08-31

Both devices were compared directly (Go over novacom, FreshPad/topaz over SSH). Ruled out first:

- **`jail_device.conf`** — the `opal` and `topaz` branches are identical apart from one tab.
- **Mount count / `/proc/mounts` size** — topaz runs **21633 bytes** of `/proc/mounts` with six jails
  and 21-23 mounts each, and its *stock* `jail_pdk.conf` already carries an extra `mount ro
  /usr/plugins` the Go's does not. PDK games are fine there. Table size is not the discriminator.

The real difference is that **the Go's kernel does not apply the read-only flag to bind mounts, and
topaz's does.** The two run different kernel builds — `2.6.35-palm-shortloin` (Go) versus
`2.6.35-palm-tenderloin` (topaz) — and every jail bind mount differs accordingly:

| `mount ro <path>` in the config | topaz | Go |
|---|---|---|
| `/lib` | `ro,nosuid,relatime` | **`rw,relatime`** |
| `/dev/input` | `ro,nosuid,relatime` | **`rw,relatime`** |

(Confirmed in `/proc/self/mountinfo`, which always shows per-mount flags, so this is not a reporting
artefact. The stock config's own comment at `mount rw /var/luna/preferences` — *"should be ro, but
the ro remount fails"* — shows Palm knew the ro step was unreliable.)

So on the Go the patch hands every jailed PDK app a **writable** handle on the device's real `/dev`.
Verified directly: creating a file inside a jail's `/dev/input` made it appear in the host's
`/dev/input`. On topaz the same mount is read-only, which is why that device's `/dev/input` is
pristine right now with three bind-mounted PDK jails live and 1.1.0 still installed.

That fully explains the input-node destruction being Go-only. It is also the leading candidate for
the graphics difference — it is the only measured behavioural difference in exactly the thing the
patch added — but the causal chain from "rw bind mount" to "surface never composited" is **still not
established**. Note that the chowned-`0555` state does *not* by itself break graphics: the doc's
stock-config control run had `/dev/input` already in that state and graphics worked.

### What is still not explained

Why one extra bind mount in the jail's `/dev` stops the app's surface being composited. The device
nodes are all created correctly with the patch applied, and jailer logs no failure. Two observations
that may matter to anyone who wants to close this out:

- ~~With the patch the app holds **two** file descriptors on the jail's `fb1`; with stock, **one**.~~
  **Ruled out 2026-08-31:** Snes9x EX holds **two** `fb1` handles in the fixed, confirmed-working
  configuration too (LunaSysMgr and WebAppMgr hold one each). The handle count was incidental.
- `/proc/mounts` on the Go is **4123 bytes with a single PDK jail present** — already past a 4 KB
  page. Base (non-jail) is 22 lines / 1562 B; each PDK jail adds 20 global mounts / ~2.5 KB. The
  patch adds a 21st. jailer itself reads `/proc/mounts` through an `ifstream` and is not affected,
  but a consumer with a single-`read()` 4096-byte buffer would be — and the Go's base mount table
  differs from a topaz's, which would explain "Go only". **Untested.**

The fix removes the mount entirely, so this is no longer on the critical path.

---

## The fix — 1.2.0, TouchPad Go only

Use jailer's `mknod` verb instead of a mount. Confirmed present in the binary
(`LunaJail::CJail::mknod(string&, string&, string&, string&)`) and confirmed working on hardware:

```
mknod <path> <c|b> <major> <minor>
```

The type char must be `b` or `c` (anything else throws); major and minor go through `strtol`; the
mode handed to `__xmknod` is `S_IFCHR`/`S_IFBLK` with **permission bits 0**, so every `mknod` needs
a `chmod` after it. A failing `mknod` only syslogs — it does not abort jail setup.

`packaging/jail-input-block.conf` is spliced in after `mkdir /dev`:

```
mkdir /dev/input
chmod 755 /dev/input
mknod /dev/input/event3 c 13 67
chmod 666 /dev/input/event3
…through event9 (13:73)
```

Why this is right:

- **No mount.** Nothing outside the jail is referenced, so no jail teardown — jailer's or a stray
  `rm -rf` — can reach the host's `/dev/input`. The mount-count/`/proc/mounts` question goes away too.
- **Nodes, not a directory view.** A minor with no device behind it just fails `open()` with
  `ENODEV`, which every evdev scanner already handles. The pad works whether it connects before or
  after the game launches.
- **Tighter than 1.1.0.** `event0`–`event2` are deliberately excluded, so jailed apps can no longer
  read the system buttons. 1.1.0 exposed the whole directory.
- **0666 in the jail is enough.** Permission is checked on the jail's own inode, so the uid-5003 app
  can open it regardless of the host node's 0640. (The udev rule stays — unjailed apps still need it.)

### Verified on hardware (Go, `opal-linux`, 2026-08-31)

Built a jail directly with `jailer -t pdk -i com.explusalpha.snes9x /bin/ls -la /dev/input` — no game
launch, so no UI freeze — with the new config installed:

```
crw-rw-rw-  1 root root  13, 67  event3     … through …
crw-rw-rw-  1 root root  13, 73  event9
```

- jail mount count: **20**, identical to stock; `grep jail/…/dev /proc/mounts` shows only
  `dev/snd`, `dev/shm`, `dev/logdir` — **no `dev/input`**.
- host `/dev/input` unchanged across both jail creation and `jailer -N` teardown.
- config restored to stock afterwards; jail nuked; device left as found.

The postinst's rewrite chain was separately unit-tested under the device's own busybox `sed`/`awk`
across five cases — fresh over stock, upgrade over 1.1.0 with and without a backup, re-run over its
own output, and a backup that was itself captured from a patched file. All five produce a file
identical to stock once the marker block is removed, with zero `mount ro /dev/input` lines.

### Confirmed on the device (2026-08-31)

1.2.0 installed on the Go and rebooted. `/etc/jail_pdk.conf` survived with 0 `mount ro /dev/input`
lines and 7 `mknod` lines; udev's coldplug repopulated `/dev/input` fully (`event0`-`event2`, the
`keypad0`-`keypad2` symlinks and `uinput`), and `hidd` now holds **live** nodes rather than
`(deleted)` ones.

Launching `Snes9x EX` builds a jail with **20 mounts — identical to stock — and zero `/dev/input`
mounts**, containing:

```
crw-rw-rw-  1 root root  13, 67 … 13, 73   event3 … event9
```

with the host's `/dev/input` completely untouched.

**Graphics confirmed working by the device owner, on both `Snes9x EX` and `Flight Control`.**

### The gamepad half — also confirmed (2026-08-31)

A DS4 paired fresh (`descriptor source: device`) and the shim created its uinput node at
**`event3` = char 13:67**, which the udev rule flipped to 0666:

```
/proc/bus/input/devices:  N: Name="Wireless Controller"   H: Handlers=diag event3
/dev/input/event3         crw-rw-rw-  1 root root  13, 67
```

That is exactly the first minor the jail block creates. Jails were built for all three PDK games on
the device (`com.emu7800.touchpad`, `com.explusalpha.snes9x`, `com.namconetworks.fc.en`) — each with
`event3`-`event9` inside it, **none with a `/dev/input` mount**, and the host's `/dev/input` intact
throughout. **Pad input in a jailed game confirmed working by the device owner.**

Both halves of the regression are now closed.

---

## Reproducing / verifying (gotchas that cost hours)

- **Take a verified-alive baseline before every launch.** The freeze is measurable without looking at
  the screen: `luna-send -i -n 1 palm://com.palm.applicationManager/listLaunchPoints '{}'` returns
  ~17 KB when healthy and nothing when wedged. A run without a pre-launch baseline is worthless —
  one earlier result was invalidated exactly this way.
- **`luna-send -i` blocks forever on subscriptions.** Background it and `kill -9` after a fixed wait.
- **An on-device script keeps running after a novacom timeout.** A timed-out run can still launch an
  app and freeze the UI behind your back, contaminating the next test.
- **Finding the app process:** `Snes9x EX` runs as `comm` = `3-armv7` with an **empty `/proc/<pid>/cmdline`**,
  so `cmdline` scans miss it entirely. On other devices (Clone Keen on a Pre 3) the reverse was true —
  `comm` missed it and only `cmdline` found it. **Scan both**, or match on open fds.
- **Never `rm -rf` a jail.** Use `jailer -N -t pdk -i <appid> /bin/true`, which unmounts first. A
  `rm -rf` on a jail with `/dev/input` bind-mounted **deletes the device's real input nodes** —
  that is how this device lost `event0`–`event2` (see Mechanism). It is also how you wedge the next
  test, because the stump left behind makes the next launch fail oddly.
- **Do not `kill -9` a PDK app holding `fb1`** — it can wedge the compositor and contaminate the next
  test. Use `SIGTERM` or `applicationManager/close`.
- **Jails are not torn down when an app exits.** They persist until something nukes them, so a stale
  jail can still be carrying the old config's mounts. Check `grep jail /proc/mounts`.
- **`/etc/jaildebug`** (an empty file is enough) turns on jailer's verbose logging; output lands in
  `/var/log/messages`. `/etc/nojail` disables jailing entirely.
- **Device type comes from `/etc/prefs/properties/machineName`** (`opal` on the Go, `topaz` on the
  TouchPad) — the same file jailer reads to pick its `jail_device.conf` branch. Use it, not
  `palm-build-info`, when something needs to be device-gated.
- `jailer: Enter failed with error: failed to make directory /var/palm/jail/<app>/etc trying setup`
  and `s9x: PmLogLib: sem_open error: Permission denied` appear in **both** the working and broken
  runs. They are noise, not the bug.

---

## Device state as left (opal-linux, TouchPad Go)

- `/etc/jail_pdk.conf` — **stock** (3977 B, md5 `659a111c…`, identical to `.btshim-orig`), so PDK
  games work and gamepad-in-jail support is currently disabled. 1.2.0 is **not** installed yet.
- `/etc/jail_pdk.conf.btshim-PATCHED-stash` — 1.1.0's patched version, kept for reference.
- `/etc/jail_pdk.conf.btshim-orig` — the shim's own stock backup, untouched.
- `/var/palm/jail/` — only `com.namconetworks.fc.en` (a stale jail from an earlier launch, 20 mounts);
  the `com.explusalpha.snes9x` jail created for the `mknod` test was nuked with `jailer -N`.
- **`/dev/input` is still empty and still owned `5241:jailuser`** — the nodes an earlier `rm -rf`
  deleted have not been recreated. Home/volume, power and headset keys have no device node until the
  next reboot (udev recreates them on coldplug). 1.2.0's postinst also recreates them directly.
- Everything else left as found: shim still preloaded into `BluetoothMonitor`, udev rule in place,
  `usbctl-watchd` running, TLS stack installed and patched, stock LunaSysMgr, Atlas restored.
