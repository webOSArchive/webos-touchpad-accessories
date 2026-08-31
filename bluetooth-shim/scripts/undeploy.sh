#!/usr/bin/env bash
# undeploy.sh -- revert deploy.sh: restore the stock upstart job, drop the shim.
set -euo pipefail
NOVACOM="${NOVACOM:-novacom}"
JOB=/etc/event.d/bluetooth
# Backup lives OUTSIDE /etc/event.d (every file there races as an upstart job).
BAK=/etc/bluetooth.upstart.btshim-orig
UDEV=/etc/udev/rules.d/99-bt-gamepad.rules
dev_sh() { $NOVACOM run file://bin/sh; }

{
  echo 'mount -o remount,rw / >/dev/null 2>&1'
  echo "if [ -f $BAK ]; then mv -f $BAK $JOB && echo job-restored; else echo 'no backup'; fi"
  # Legacy wrapper cleanup (in case an old deploy renamed the binary).
  echo '[ -f /usr/bin/PmBtEngine.real ] && mv -f /usr/bin/PmBtEngine.real /usr/bin/PmBtEngine && echo bin-restored || true'
  echo 'rm -f /usr/lib/libpmbtgamepad.so && echo shim-removed'
  echo "rm -f $UDEV && echo udev-rule-removed"
  # drop any live 1.1.0 bind mount BEFORE touching the jail -- while one is
  # mounted, deleting the jail directory deletes the host's real input nodes
  echo 'grep " /var/palm/jail/[^ ]*/dev/input " /proc/mounts 2>/dev/null | cut -d" " -f2 | while read -r M; do umount "$M" 2>/dev/null && echo "unmounted stale $M"; done'
  # restore the stock PDK jail (or strip our lines if there is no backup)
  echo 'if [ -f /etc/jail_pdk.conf.btshim-orig ]; then mv -f /etc/jail_pdk.conf.btshim-orig /etc/jail_pdk.conf && echo jail-restored; else sed -i -e "/^# >>> btgamepad begin/,/^# <<< btgamepad end/d" -e "/^mkdir \/dev\/input$/d" -e "/^mount ro \/dev\/input$/d" /etc/jail_pdk.conf && echo jail-lines-stripped; fi'
  echo 'kill -HUP 1 2>/dev/null; killall PmBtEngine 2>/dev/null; killall BluetoothMonitor 2>/dev/null; echo bt-restarted'
} | dev_sh
echo ">> reverted."
