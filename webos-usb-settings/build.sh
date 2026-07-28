#!/bin/bash
#
# Build com.webosarchive.usbsettings (Enyo app + JS service), then repack the
# .ipk to inject postinst/prerm so a Preware/WOSQI install sets up the root
# daemon. Output goes to the shared project-root ipks/ folder.
#
# Install via Preware or WebOS Quick Install -- NOT palm-install (which runs the
# control scripts as a non-root user, so the daemon never gets installed).
#
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
PALM_PACKAGE="${PALM_PACKAGE:-/opt/PalmSDK/Current/bin/palm-package}"

APP=com.webosarchive.usbsettings
PKG=com.webosarchive.usbsettings.package
SVC=com.webosarchive.usbsettings.service

echo ">> palm-package ($APP + $SVC)"
"$PALM_PACKAGE" "$PKG" "$APP" "$SVC"

IPK=$(ls -t "$SCRIPT_DIR"/*.ipk 2>/dev/null | head -1)
[ -n "$IPK" ] || { echo "ERROR: palm-package produced no .ipk"; exit 1; }
echo ">> base package: $(basename "$IPK")"

echo ">> injecting postinst/prerm"
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
( cd "$WORK" && ar x "$IPK" )
mkdir -p "$WORK/ctrl"
tar -xzf "$WORK/control.tar.gz" -C "$WORK/ctrl"
cp "$SCRIPT_DIR/postinst" "$WORK/ctrl/postinst"
cp "$SCRIPT_DIR/prerm"    "$WORK/ctrl/prerm"
chmod 755 "$WORK/ctrl/postinst" "$WORK/ctrl/prerm"
( cd "$WORK/ctrl" && tar --owner=0 --group=0 -czf "$WORK/control.tar.gz" . )
( cd "$WORK" && ar rc repacked.ipk debian-binary control.tar.gz data.tar.gz )

# write the final ipk to the shared project-root ipks/ folder
OUTDIR="$SCRIPT_DIR/../ipks"
mkdir -p "$OUTDIR"
OUT="$OUTDIR/$(basename "$IPK")"
mv "$WORK/repacked.ipk" "$OUT"
rm -f "$IPK"

echo ">> built $OUT"
echo ">> ar members:"; ar t "$OUT"
echo ">> control.tar.gz contents:"; tar -tzf <(ar p "$OUT" control.tar.gz)
echo ">> md5: $(md5sum "$OUT" | cut -d' ' -f1)  size: $(stat -c%s "$OUT")"
