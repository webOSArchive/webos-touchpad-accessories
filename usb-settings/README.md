# USB Settings (com.webosarchive.usbsettings)

A Palm-style settings app for the HP TouchPad that toggles the USB capabilities
the stock OS hides:

- **USB Host (OTG)** — switch the port into host mode so USB keyboards, game
  controllers and flash drives work. (While on, USB charging and USB computer
  sync are unavailable — the port can't be both.)
- **High-power devices** — bypass the root hub's ~390 mA budget so a device that
  declares more (e.g. a DualShock 4 at 500 mA) actually configures instead of
  being rejected. Turn on before plugging the device in; it applies to devices as
  they attach.
- **USB Storage** — mount/unmount a plugged-in USB flash drive (VFAT).

## Why it needs a helper (the architecture)

webOS apps — and their bundled JS services — run in a **jail**: non-root, with no
write access to `/sys` and no `mount`. So the app can't do any of this directly.
Instead (the ACL Manager pattern):

```
[Enyo app]  --calls-->  [JS service (jailed)]  --writes--> /media/internal/.usbctl-control
                                                                    |  (polled 1 Hz)
[Enyo app]  <--reads--   [JS service]  <--reads-- /media/internal/.usbctl-status
                                                                    ^
                                              [usbctl-watchd (root, upstart)]
                                              mounts debugfs, echo>otg/mode,
                                              bConfigurationValue, mount/umount
```

`/media/internal` is the only path visible to both the jail and the root daemon.
The daemon does the privileged work and writes status back; the app polls it.

## Components

| Path on device | What |
|---|---|
| `/usr/palm/applications/com.webosarchive.usbsettings/` | Enyo app (UI) |
| `/usr/palm/services/com.webosarchive.usbsettings.service/` | JS bridge service |
| `/usr/bin/usbctl-watchd` | root daemon (installed by postinst) |
| `/usr/bin/usbctl-jsservice` | self-contained JS-service launcher (no external framework dep) |
| `/etc/event.d/usbctl-watchd` | upstart job (auto-start on boot) |
| `/media/internal/.usbctl-{control,status,state}` | IPC + persisted flags |
| `/media/usb` | USB flash-drive mountpoint. Falls back to `/media/internal/usbdrive` if the root fs is read-only and the directory cannot be created |

### Why the mountpoint is not inside `/media/internal`

It used to be `/media/internal/usbdrive`, on the reasoning that the root fs (and
so `/media`) is read-only on a stock device while `/media/internal` is the
writable user partition every file manager browses. That backfired.

**Internalz Pro cannot see a drive mounted under `/media/internal`.** Its
backend, FileMgr-Service, lists any path under that prefix with **mtools** —
`mdir` against `mtools.conf`'s `drive A: file="/dev/mapper/store-media"` —
whenever the caller asks to hide hidden files, which is Internalz's default.
mtools parses the internal partition's FAT directly and is blind to the kernel
mount table, so a stick mounted at a subdirectory of that volume lists as an
empty folder. Verified on webOS 3.0.5: `mdir -f "A:/usbdrive/"` returns only
`.` and `..` while the same directory has files in it.

So we mount at `/media/usb`, which takes FileMgr's plain `readdir` path.
Confirmed working: listing with hidden-filtering on, plus read/write/create/
delete through the service. Two things to know:

- Creating `/media/usb` needs a writable root fs (`rootfs_open -w`), which
  Preware/webOS Internals users have. The daemon falls back to the old
  in-partition path when `mkdir` fails, so a locked-down device still mounts —
  it just keeps the Internalz blindness.
- Don't pick a name like `/media/internal-usb`: FileMgr's test is a bare
  `startsWith("/media/internal")` with no trailing slash.

Trade-offs of moving out of the media partition: webOS's own file indexer only
scans `/media/internal`, so photos/music on the stick no longer show up in the
stock Photos/Music apps, and Internalz opens at `/media/internal/` so the drive
is no longer one tap away (add a favourite). Also note FileMgr's
`writePermissable()` whitelist is `/media/cryptofs/apps/`, `/media/internal/`
and `/var/` — `/media/usb` is not on it, and writes only succeed because of a
separate bug (`if(appid = "ca.canucksoftware.internalz")`, an assignment, makes
that check always take the `rootfs_open` branch). If that typo is ever fixed
upstream, `/media/usb` needs adding to the whitelist.

## Build

```sh
./build.sh            # -> ../ipks/com.webosarchive.usbsettings_<ver>_all.ipk
```
Runs `palm-package` on the app + service + package dirs, then repacks the `.ipk`
to inject `postinst`/`prerm` (which install/remove the daemon and upstart job).

## Install

**Preware or WebOS Quick Install only — NOT `palm-install`.** palm-install runs
the control scripts as a non-root user, so the daemon never gets set up and the
toggles do nothing. Distributed via the WOSA Modernize feed.

## Uninstall

**Remove through Preware or WebOS Quick Install — not the launcher's Delete.**

The app ships `"removable": false` in `appinfo.json`, so the launcher deliberately
offers no Delete button. webOS's built-in launcher delete removes only the app
package and does **not** run our `prerm` — it would leave the root daemon still
running (the leftover upstart job even restarts it on boot) plus its `/usr/bin`
binaries and LS2 service files orphaned on the device. Preware/WOSQI run `prerm`,
which stops the daemon and removes every component cleanly (and, because the root
fs is read-only on a stock device, `prerm`/`postinst` remount it `rw` around the
`/usr/bin` and `/etc/event.d` writes, then restore `ro`).

## Notes / caveats

- **No BLE, no magic** — this only exposes kernel/USB capabilities that already
  exist; it doesn't add drivers. Tested devices are the same as the
  `webos-touchpad-accessories` repo's tested-hardware table.
- **OTG mode reverts on reboot** (kernel boots in peripheral mode); the daemon
  resets its OTG flag to match at startup. The high-power preference persists.
- **Unplug safely** — always unmount storage before removing a drive. Unplugging
  a device in host mode can trigger an IRQ storm the OS recovers from by cycling
  OTG; if USB goes dead, toggle host mode off and on.
