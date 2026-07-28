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
| `/etc/event.d/usbctl-watchd` | upstart job (auto-start on boot) |
| `/media/internal/.usbctl-{control,status,state}` | IPC + persisted flags |

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

## Notes / caveats

- **No BLE, no magic** — this only exposes kernel/USB capabilities that already
  exist; it doesn't add drivers. Tested devices are the same as the
  `webos-touchpad-accessories` repo's tested-hardware table.
- **OTG mode reverts on reboot** (kernel boots in peripheral mode); the daemon
  resets its OTG flag to match at startup. The high-power preference persists.
- **Unplug safely** — always unmount storage before removing a drive. Unplugging
  a device in host mode can trigger an IRQ storm the OS recovers from by cycling
  OTG; if USB goes dead, toggle host mode off and on.
