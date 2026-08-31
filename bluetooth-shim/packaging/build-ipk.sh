#!/usr/bin/env bash
# build-ipk.sh -- assemble org.webosarchive.btgamepad_<ver>_armv7.ipk
# Payload: the built shim + udev rule + PDK jail block. Control: control.in
# (version/date/device filled), postinst, prerm. Written to project-root ipks/.
#
# Usage:
#   ./build-ipk.sh [version] [--go]
#
# --go builds the TouchPad Go-only variant: same Package name, so Preware
# treats it as an upgrade, but DeviceCompatibility lists only the Go so it is
# offered from a Go feed alone. Without --go the package advertises both
# devices, as 1.1.0 did.
#
# Note the postinst gates the jail-config change on machineName == opal either
# way -- the --go flag only controls what the feed advertises.
set -euo pipefail
cd "$(dirname "$0")"

PID=org.webosarchive.btgamepad
VERSION="${1:-1.2.0}"
GO_ONLY=0
for a in "$@"; do [ "$a" = "--go" ] && GO_ONLY=1; done
ARCH=armv7
SHIM=../libpmbtgamepad.so
STAMP="$(date +%s)"
OUTDIR="../../ipks"          # project-root ipks/ folder

FIX_NOTE="<br><br><b>1.2.0 (TouchPad Go):</b> fixes PDK ('Linux binary') games starting with sound but a black screen after 1.1.0 was installed. 1.1.0 exposed the gamepad to jailed games by bind-mounting the system input directory into the app jail; on the Go that breaks the display handover, and while mounted it also let a jail teardown delete the device's real input nodes. 1.2.0 creates the gamepad nodes inside the jail instead, so nothing outside the jail is touched. Upgrading repairs a device already affected."

if [ "$GO_ONLY" = 1 ]; then
    SHORTDEV="HP TouchPad Go"
    TITLE="Bluetooth Gamepad Support (TouchPad Go)"
    DEVICECOMPAT='["Touchpad Go"]'
    OUT="${PID}_${VERSION}_${ARCH}-go.ipk"
else
    SHORTDEV="HP TouchPad"
    TITLE="Bluetooth Gamepad Support"
    DEVICECOMPAT='["TouchPad","Touchpad Go"]'
    OUT="${PID}_${VERSION}_${ARCH}.ipk"
fi

FULLDESC="Adds Bluetooth game-controller support to the ${SHORTDEV} by interposing the stock (unfinished) Bluetooth HID path -- no binary patching. A DualShock 4 (and other classic BR/EDR HID pads) pairs and appears to apps as a real gamepad: both sticks, analog triggers, d-pad and all buttons. Games read it as a standard Linux input device.<br><br><b>Tested so far: DualShock 4 only.</b> Other classic BR/EDR HID controllers should work (the shim is descriptor-driven) but are unverified.<br><br>Pairing: open Bluetooth settings, tap Add device, and put the pad in pairing mode -- it appears under the <b>Other</b> category. Pair it and it connects automatically. Later, press the pad's connect button (PS on a DS4), or tap it in the device list, to reconnect.<br><br><b>No Bluetooth LE.</b> The radio is Bluetooth 2.1+EDR, so BLE-only controllers (Xbox One/Series and similar) cannot work -- this is a hardware limit.${FIX_NOTE}<br><br>Fully reversible; uninstall restores stock Bluetooth. Based on Herrie82's webos-bt-shim."

# 1. ensure the shim is built
if [ ! -f "$SHIM" ]; then
    echo ">> shim not built; running make in $(cd .. && pwd)"
    ( cd .. && make )
fi
file "$SHIM" | grep -q ARM || { echo "ERROR: $SHIM is not an ARM binary"; exit 1; }

BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT
mkdir -p "$BUILD/control" "$BUILD/data/usr/palm/applications/$PID/files"

# 2. payload
cp "$SHIM"                  "$BUILD/data/usr/palm/applications/$PID/files/libpmbtgamepad.so"
cp 99-bt-gamepad.rules      "$BUILD/data/usr/palm/applications/$PID/files/99-bt-gamepad.rules"
cp jail-input-block.conf    "$BUILD/data/usr/palm/applications/$PID/files/jail-input-block.conf"

# 3. control (fill version + timestamp + device), maintainer scripts
# sed replacements must have & and the | delimiter escaped, or an unescaped &
# silently re-inserts the placeholder it just matched.
esc() { printf '%s' "$1" | sed -e 's/[&|\\]/\\&/g'; }
sed -e "s|@VERSION@|$(esc "$VERSION")|" \
    -e "s|@LASTUPDATED@|$(esc "$STAMP")|" \
    -e "s|@SHORTDEV@|$(esc "$SHORTDEV")|" \
    -e "s|@TITLE@|$(esc "$TITLE")|" \
    -e "s|@DEVICECOMPAT@|$(esc "$DEVICECOMPAT")|" \
    -e "s|@FULLDESC@|$(esc "$FULLDESC")|" \
    control/control.in > "$BUILD/control/control"
grep -q '@[A-Z]*@' "$BUILD/control/control" && { echo "ERROR: unsubstituted placeholder in control"; exit 1; }
install -m 0755 control/postinst "$BUILD/control/postinst"
install -m 0755 control/prerm    "$BUILD/control/prerm"

# sanity: the Source JSON must still parse (Preware does JSON.parse on it)
if command -v python3 >/dev/null; then
    python3 - "$BUILD/control/control" <<'PY'
import json, sys
for line in open(sys.argv[1]):
    if line.startswith("Source: "):
        json.loads(line[len("Source: "):])
        print(">> Source JSON parses OK")
        break
else:
    sys.exit("ERROR: no Source line in control")
PY
fi

# 4. assemble ipk (debian-binary + control.tar.gz + data.tar.gz, this member order)
printf '2.0\n' > "$BUILD/debian-binary"
( cd "$BUILD/control" && tar --owner=0 --group=0 -czf ../control.tar.gz . )
( cd "$BUILD/data"    && tar --owner=0 --group=0 -czf ../data.tar.gz . )
( cd "$BUILD" && ar rc "$OUT" debian-binary control.tar.gz data.tar.gz )
mkdir -p "$OUTDIR"
cp "$BUILD/$OUT" "$OUTDIR/$OUT"

MD5="$(md5sum "$OUTDIR/$OUT" | cut -d' ' -f1)"
SIZE="$(stat -c%s "$OUTDIR/$OUT")"

# 5. regenerate the feed stanza. Doing this here rather than by hand is the point:
#    MD5Sum and Size change on every build (LastUpdated is stamped at build time),
#    and a stale stanza is a silently broken feed entry.
STANZA="Packages-stanza.txt"
[ "$GO_ONLY" = 1 ] && STANZA="Packages-stanza-go.txt"
{
    grep '^Package: '      "$BUILD/control/control"
    grep '^Version: '      "$BUILD/control/control"
    grep '^Section: '      "$BUILD/control/control"
    grep '^Architecture: ' "$BUILD/control/control"
    echo "MD5Sum: $MD5"
    echo "Size: $SIZE"
    echo "Filename: $OUT"
    grep '^Description: '  "$BUILD/control/control"
    grep '^Maintainer: '   "$BUILD/control/control"
    grep '^Source: '       "$BUILD/control/control"
} > "$STANZA"

echo ">> built $OUTDIR/$OUT"
ls -la "$OUTDIR/$OUT"
echo ">> md5: $MD5  size: $SIZE"
echo ">> feed stanza regenerated: packaging/$STANZA"
