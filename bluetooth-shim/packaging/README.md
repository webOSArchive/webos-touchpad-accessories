# btgamepad — Preware/WOSQI package for the Bluetooth gamepad stack

Packages the whole working setup (`libpmbtgamepad.so` + the system changes it
needs) into one installable `.ipk` for the **WOSA Modernize** feed.

## Build

```sh
./build-ipk.sh [version] [--go]   # default 1.2.0
# -> org.webosarchive.btgamepad_<version>_armv7.ipk        (both devices)
# -> org.webosarchive.btgamepad_<version>_armv7-go.ipk     (--go: TouchPad Go only)
```
`--go` keeps the same `Package:` name — so Preware treats it as an upgrade of an
installed 1.1.0 — but narrows `DeviceCompatibility` to `["Touchpad Go"]` so only
a Go is offered it. The postinst gates the jail-config change on
`machineName == opal` independently, so the build flag only controls what the
feed advertises.
Builds the shim (`make` in the parent) if needed, assembles the ipk
(`debian-binary` + `control.tar.gz` + `data.tar.gz`, in that ar member order),
and prints the md5/size. Regenerate `Packages-stanza.txt` after any rebuild —
the md5 changes because `LastUpdated` is stamped at build time.

## What the package does (postinst, as root, idempotent)

1. installs `/usr/lib/libpmbtgamepad.so`
2. installs `/etc/udev/rules.d/99-bt-gamepad.rules` (pad node → 0666 for jailed apps)
3. adds the gamepad event nodes to the PDK jail (`/etc/jail_pdk.conf`) — **opal
   (TouchPad Go) only**; on any other machine the file is left exactly as found.
   The block spliced in is `jail-input-block.conf`: jailer `mknod` verbs that
   create `/dev/input/event3`–`event9` (char 13:67–13:73, chmod 666) *inside*
   the jail.

   1.1.0 did this with `mount ro /dev/input`, which is a genuine **bind mount**
   of the host's `/dev/input`. That blacks out PDK games on the Go, and while it
   is mounted anything that deletes the jail directory deletes the device's real
   input nodes. See `../docs/PDK-GRAPHICS-REGRESSION.md`. postinst also unmounts
   any such leftover mount and recreates input nodes a 1.1.0 teardown deleted —
   both on every machine, since neither is a config change.
4. patches the Bluetooth settings app (`models/Bluetooth.js` + `controllers/bluetooth-assistant.js`)
   so a gamepad paired from the **Other** category HID-connects (auto after
   pairing, on tap-to-reconnect, and device-initiated) — three edits that add
   `isGamepad`/`isMouse` to checks that stock gated on `isKeyboard` only. No
   `DeviceClass.js` change: the pad stays under Other where users expect it.
5. rewrites `/etc/event.d/bluetooth` to `LD_PRELOAD` the shim into PmBtEngine and
   force `sysrq=0` (dump logging **off** in this build: `WEBOS_BT_SHIM_DUMP=0`)

Every step backs up what it changes; **prerm restores all of it** (removal +
reboot = bit-for-bit stock Bluetooth).

### The reboot is declared, not forced

postinst does **not** reboot. The control's `Source` JSON carries
`"PostInstallFlags":"RestartDevice"` (and `PostUpdateFlags`), so Preware performs
the reboot and can **stack** it with other packages in the same batch. The
upstart-job change (step 5) only takes effect after that reboot.

## Do NOT install this with `palm-install`

`palm-install` (and the `ApplicationInstallerUtility` path behind it) runs
`ipkg -o /media/cryptofs/apps … install`, i.e. **offline-root mode, which does not
run a Debian `postinst`** — it extracts the payload, registers the package, and
defers. It then looks for a Palm-convention `pmPostInstall.script`, does not find
one in a Preware-style ipk, writes a **0-byte** file and runs that, logging
`result = 1`. The install looks like it succeeded and applies nothing.

Confirmed on the Go 2026-08-31. Preware and WOSQI use a path that does run
`postinst`. To finish a `palm-install` by hand, run the extracted script:

```sh
sh /media/cryptofs/apps/usr/lib/ipkg/info/org.webosarchive.btgamepad.postinst
```

## Install (WOSQI, manual)

WebOS Quick Install → Install package → pick the `.ipk`. WOSQI does not process
`PostInstallFlags`, so **reboot the device manually** after it installs. Then:
Bluetooth settings → Add device, put the pad in pairing mode, pair it from the
**Other** category (it connects automatically), and launch a gamepad-aware app.

## Add to the modernize feed

1. copy the `.ipk` into the feed's `ipkgs/`
2. append `Packages-stanza.txt` to `ipkgs/Packages` (keep existing stanzas verbatim)
3. regenerate `Packages.gz` (`gzip -n`, mtime 0) and `cmp` it against `Packages`

### If the shipped artifact was not built by this script

`MD5Sum` and `Size` change on **every** build — `LastUpdated` is stamped at build
time — so you cannot refresh a stanza by rebuilding: you would get a stanza
describing a file nobody has, and Preware rejects the download on hash mismatch.
When the artifact that actually ships is a repack or otherwise came from
elsewhere, generate the stanza *from that file*:

```sh
./build-ipk.sh --stanza-from ../../ipks/org.webosarchive.btgamepad_1.2.0_armv7-go.ipk
```

It reads the `control` back out of the ipk and hashes the real file. The output
filename (`Packages-stanza.txt` vs `-go.txt`) is picked from the ipk's own
`DeviceCompatibility`.

## 1.2.0 as shipped vs this tree

The 1.2.0 that shipped was **repacked by the feed tooling**, and `ipks/` holds
that exact artifact (md5 `8c637397…`, 20150 B) rather than a local build. Its
payload, `control` and `prerm` are byte-identical to a build from this tree; its
`postinst` carries two changes, both folded back into `control/postinst` here:

- **the device gate was restructured** — `machineName` not being a Go is now
  reported separately from `jail_pdk.conf` being absent. This tree's original
  collapsed both into one `else` and would print "machine 'opal' is not opal"
  when the config was simply missing. The repack is correct; adopted.
- **`shortloin` accepted alongside `opal`.** Kept (it is harmless and does not
  weaken the topaz protection — verified across `opal`/`shortloin`/`topaz`/empty/
  unknown), but the shipped comment justifying it is **wrong** and is corrected
  here: `machineName` on the Go is `opal`. `shortloin` is the *kernel* name
  (`uname -r` = `2.6.35-palm-shortloin`), exactly as the TouchPad's kernel is
  `palm-tenderloin` while its `machineName` is `topaz`. No stock
  `jail_device.conf` has a `shortloin` branch, so a unit reporting it would fall
  through to that file's own `ERROR: no device-specific setting` and get no
  kgsl/pmem/fb1 nodes — PDK games would be broken there for unrelated reasons.

So `control/postinst` in this tree differs from the shipped one **in comments
only**; the executable code is identical (verified by diffing both with comments
and blank lines stripped).

## Validated

- ipk structure (ar members, tar roots) — correct.
- v1.0.0 fresh-Preware install applied 5/6 changes; the 6th (BT-app patch) was
  silently skipped by a non-unique idempotency guard — fixed in 1.0.1, then the
  whole BT-app patch was redesigned in 1.1.0 (see below).
- 1.1.0 BT-app edits (3 seds) validated under **busybox sed** on-device: all
  three apply once, line counts unchanged, guards are idempotent; both patched
  files pass `node --check`.
- Source JSON parses (Preware-style `JSON.parse`).
- **1.2.0 (2026-08-31, TouchPad Go):** `jailer`'s `mknod` verb confirmed working on
  hardware — a jail built with the new config gets `crw-rw-rw- 13,67…13,73` nodes,
  the jail's mount count is unchanged at 20, and the host's `/dev/input` survives
  both jail creation and `jailer -N` teardown. The postinst rewrite chain was
  unit-tested under the device's own busybox across five cases (fresh, upgrade
  with/without backup, re-run, and a backup captured from a patched file) — all
  produce a file identical to stock once the marker block is removed.
  **Installed on the Go and confirmed by the device owner: `Snes9x EX` and
  `Flight Control` both draw again.** The jail they build has 20 mounts (identical
  to stock), zero `/dev/input` mounts, `event3`–`event9` inside it, and leaves the
  host's `/dev/input` untouched. **The gamepad half is confirmed too:** a DS4 paired
  fresh, the shim's uinput node landed at `event3` (13:67) — the first minor the
  block creates — and pad input in a jailed game was confirmed by the device owner.
- **Confirmed on hardware (2026-07-28):** clean WOSQI install on a fresh device →
  reboot → pair a DS4 from the "Other" category → auto-connects as a gamepad, no
  radio cycle. Also verified: press-PS reconnect of a bonded pad, and play in
  Clone Keen.

## Controller scope — only the DS4 is confirmed

**The Sony DualShock 4 (`054c:05c4`) is the only controller tested on hardware.**
The shim is descriptor-driven, so other **classic BR/EDR HID** pads *should* work
— a pad that presents a clean HID descriptor on pairing works with no table entry
(the shim parses/caches it), and a built-in descriptor covers the DS4 by VID/PID —
but none of these are verified. See the tested-hardware table in the top-level
`README.md`, and grow the built-in table as controllers are confirmed.

**No BLE.** The TouchPad radio is BT 2.1+EDR — BLE-only controllers (Xbox
One/Series, 8BitDo in BLE mode, etc.) cannot work. Hardware limit, not fixable.
