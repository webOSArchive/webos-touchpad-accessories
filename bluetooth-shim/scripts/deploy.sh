#!/usr/bin/env bash
#
# deploy.sh -- install/update the shim on a novacom-connected TouchPad.
#
# Injection: LD_PRELOAD is set in BluetoothMonitor's environment via the upstart
# job /etc/event.d/bluetooth (it fork-execs PmBtEngine, so the env is inherited
# while the exe path stays /usr/bin/PmBtEngine -- required for its ls-hubd role).
#
# IMPORTANT lesson learned: this webOS upstart (0.3.x) does NOT reliably reload a
# changed /etc/event.d job at runtime (kill -HUP 1 / initctl restart keep the
# stale in-memory definition, so BluetoothMonitor respawns WITHOUT the env).
# Only a reboot re-parses the job. Therefore:
#   * Updating just the .so  -> push it + kill PmBtEngine (BluetoothMonitor, which
#     already carries the env from boot, respawns PmBtEngine and loads the new .so).
#     NO reboot, NO monitor restart.
#   * Changing the upstart job (first install / env change) -> REBOOT to apply.
#
# Usage:
#   scripts/deploy.sh            # update .so (+ ensure job present); reload PmBtEngine
#   scripts/deploy.sh --setup    # (re)write the upstart job too -> then REBOOT
#
set -euo pipefail
NOVACOM="${NOVACOM:-novacom}"
SO_LOCAL="${SO_LOCAL:-libpmbtgamepad.so}"
SO_REMOTE=/usr/lib/libpmbtgamepad.so
JAILBLOCK="${JAILBLOCK:-$(dirname "$0")/../packaging/jail-input-block.conf}"
JOB=/etc/event.d/bluetooth
# NEVER store the backup inside /etc/event.d -- upstart treats every file there
# as a job, so a backup copy would race the real one at boot (learned the hard
# way on this device with novacomd).
BAK=/etc/bluetooth.upstart.btshim-orig
LOG=/var/log/btshim.log
MON=/usr/bin/BluetoothMonitor
SETUP=0
[ "${1:-}" = "--setup" ] && SETUP=1
dev_sh() { $NOVACOM run file://bin/sh; }

[ -f "$SO_LOCAL" ] || { echo "build first: make"; exit 1; }

echo ">> remount / rw + push $SO_LOCAL"
echo 'mount -o remount,rw / >/dev/null 2>&1 && echo remounted' | dev_sh
$NOVACOM put file://"$SO_REMOTE" < "$SO_LOCAL"

if [ "$SETUP" = 1 ]; then
  echo ">> installing udev rule so the gamepad node is readable by jailed apps"
  # Launcher-started PDK apps run as uid 5003 and can't read the default
  # 0640 root:root /dev/input/event*. This rule makes the shim's gamepad node
  # world-readable; udev applies the mode itself (no chmod race). Verified on
  # device: node flips to 0666 on connect.
  {
    echo 'mount -o remount,rw / >/dev/null 2>&1'
    echo "cat > /etc/udev/rules.d/99-bt-gamepad.rules <<'UDEVEOF'"
    echo 'SUBSYSTEM=="input", KERNEL=="event[0-9]*", ATTRS{name}=="Wireless Controller", MODE="0666"'
    echo 'UDEVEOF'
    echo '/sbin/udevcontrol reload_rules 2>/dev/null; echo udev-rule-installed'
  } | dev_sh
  echo ">> exposing the gamepad inside the PDK app jail (so games can read the pad)"
  # Launcher-started PDK apps run in a jail whose /dev is a copynod whitelist
  # with no /dev/input. We add the event nodes with jailer's `mknod` verb, which
  # creates them INSIDE the jail -- no mount, nothing on the host referenced.
  #
  # Do NOT go back to `mount ro /dev/input`: that is a real bind mount of the
  # host's /dev/input, it blacks out PDK games on the Go, and while it is live
  # anything that deletes the jail dir deletes the device's real input nodes.
  # See docs/PDK-GRAPHICS-REGRESSION.md.
  #
  # Idempotent: always regenerated from the stock backup. Takes effect on the
  # next app launch (jailer re-runs setup per launch; no reboot).
  $NOVACOM put file:///tmp/jail-input-block.conf < "$JAILBLOCK"
  {
    echo 'mount -o remount,rw / >/dev/null 2>&1'
    echo 'JPK=/etc/jail_pdk.conf; JPKORIG=$JPK.btshim-orig'
    # strip anything either shim version could have added, so we always start
    # from a genuinely stock file
    echo 'strip_btshim() { sed -e "/^# >>> btgamepad begin/,/^# <<< btgamepad end/d" -e "/^mkdir \/dev\/input$/d" -e "/^mount ro \/dev\/input$/d" "$1"; }'
    echo '[ -f "$JPKORIG" ] || strip_btshim "$JPK" > "$JPKORIG"'
    echo 'strip_btshim "$JPKORIG" > /tmp/jpk-src.$$'
    echo 'awk -v blk=/tmp/jail-input-block.conf '"'"'{print} /^mkdir \/dev$/ && !d {while ((getline l < blk) > 0) print l; d=1}'"'"' /tmp/jpk-src.$$ > /tmp/jpk.$$'
    echo 'if grep -q "^mknod /dev/input/event3 c 13 67$" /tmp/jpk.$$; then cp /tmp/jpk.$$ "$JPK"; echo jail-patched; else echo JAIL-PATCH-FAILED; fi'
    echo 'rm -f /tmp/jpk-src.$$ /tmp/jpk.$$'
    # drop any live bind mount left over from the old approach
    echo 'grep " /var/palm/jail/[^ ]*/dev/input " /proc/mounts 2>/dev/null | cut -d" " -f2 | while read -r M; do umount "$M" 2>/dev/null && echo "unmounted stale $M"; done'
  } | dev_sh
  echo ">> (re)writing upstart job (backup -> $BAK)"
  {
    echo "[ -f $BAK ] || cp $JOB $BAK"
    echo "cat > $JOB <<'JOBEOF'"
    echo 'description "Palm Bluetooth"'; echo
    echo 'start on stopped finish'; echo
    echo 'respawn'
    # sysrq off: Palm's keyboard uinput node has the sysrq handler attached, and
    # report bytes landing on KEY_SYSRQ have panicked this device before.
    # Something re-enables sysrq at runtime, so clear it every time BT starts.
    echo "exec /bin/sh -c 'echo 0 > /proc/sys/kernel/sysrq; export LD_PRELOAD=$SO_REMOTE; export WEBOS_BT_SHIM_LOG=$LOG; export WEBOS_BT_SHIM_DUMP=1; exec $MON'"
    echo 'JOBEOF'
    echo 'echo job-written'
  } | dev_sh
  echo ">> job written.  REBOOT the device now to apply it:"
  echo "     $NOVACOM run file://sbin/reboot"
  exit 0
fi

echo ">> reloading: kill PmBtEngine so BluetoothMonitor respawns it with the new .so"
echo 'rm -f '"$LOG"'; killall PmBtEngine 2>/dev/null; sleep 3; echo done' | dev_sh
echo ">> checking the shim actually mapped in..."
echo 'PE=$(pidof PmBtEngine); if grep -q libpmbtgamepad /proc/$PE/maps 2>/dev/null || grep -q loaded '"$LOG"' 2>/dev/null; then echo "OK: shim active"; else echo "NOT LOADED -- BluetoothMonitor lacks the env; run: scripts/deploy.sh --setup  then REBOOT"; fi' | dev_sh
