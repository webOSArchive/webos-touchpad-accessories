#!/bin/sh
#
# usbctl-watchd - USB control watch daemon for com.webosarchive.usbsettings
#
# Runs as ROOT outside the webOS app jail (via upstart). The jailed app can't
# touch /sys or mount, so its JS service writes one-word commands to the control
# file and this daemon performs them, writing current state back to the status
# file. IPC lives in /media/internal (the only path shared by jail + system).
#
#   control : /media/internal/.usbctl-control   (app -> daemon, consumed once)
#   status  : /media/internal/.usbctl-status    (daemon -> app, JSON, ~1s fresh)
#   state   : /media/internal/.usbctl-state     (daemon's own persisted flags)
#
# Commands: otg-host otg-peripheral power-on power-off mount unmount refresh
#
CONTROL=/media/internal/.usbctl-control
STATUS=/media/internal/.usbctl-status
STATE=/media/internal/.usbctl-state
OTG=/sys/kernel/debug/otg/mode
# The root fs (and thus /media) is mounted READ-ONLY on a stock device, so we
# cannot create a mountpoint there. /media/internal is the writable user
# storage partition and is exactly where webOS file managers browse, so the
# stick shows up as a folder the user can open.
MNT=/media/internal/usbdrive
LOG=/tmp/usbctl-watchd.log

log() { echo "$(date '+%H:%M:%S') usbctl: $*" >> "$LOG" 2>&1; }

# debugfs holds the OTG mode knob; mount it if it isn't already (idempotent).
ensure_debugfs() { [ -e "$OTG" ] || mount -t debugfs none /sys/kernel/debug 2>/dev/null; }

# --- persisted flags (otg + power mode; storage/present are probed live) ------
get_flag() { grep "^$1=" "$STATE" 2>/dev/null | cut -d= -f2; }
set_flag() {
    tmp="$STATE.tmp.$$"; touch "$STATE" 2>/dev/null
    grep -v "^$1=" "$STATE" 2>/dev/null > "$tmp"; echo "$1=$2" >> "$tmp"
    mv -f "$tmp" "$STATE" 2>/dev/null
}

# --- operations ---------------------------------------------------------------
otg_set() {   # $1 = host | peripheral
    ensure_debugfs
    if echo "$1" > "$OTG" 2>/dev/null; then set_flag otg "$1"; log "otg -> $1"
    else log "otg write failed ($1)"; fi
}

# High-power mode: the root hub budgets ~390mA and rejects a config that asks
# for more (a DS4 declares 500mA -> bConfigurationValue stays 0). Force config 1
# on any attached-but-unconfigured device. While the flag is on, we re-apply it
# each loop so freshly-plugged devices get configured too.
power_apply() {
    for cv in /sys/bus/usb/devices/*/bConfigurationValue; do
        [ -e "$cv" ] || continue
        [ "$(cat "$cv" 2>/dev/null)" = "0" ] || continue
        d=$(dirname "$cv"); [ "$(cat "$d/bNumConfigurations" 2>/dev/null)" -ge 1 ] 2>/dev/null || continue
        echo 1 > "$cv" 2>/dev/null && log "high-power: configured $(basename $d)"
    done
}

storage_dev() { for d in /dev/sda1 /dev/sda /dev/sdb1 /dev/sdb; do [ -b "$d" ] && { echo "$d"; return; }; done; }
storage_mount() {
    dev=$(storage_dev); [ -n "$dev" ] || { log "mount: no block device"; return; }
    grep -q " $MNT " /proc/mounts 2>/dev/null && { log "mount: already mounted"; return; }
    mkdir -p "$MNT" 2>>"$LOG" || { log "mount: cannot create mountpoint $MNT"; return; }
    if mount -t vfat -o utf8 "$dev" "$MNT" 2>>"$LOG" || mount "$dev" "$MNT" 2>>"$LOG"
    then log "mounted $dev at $MNT"; else log "mount $dev failed"; fi
}
storage_unmount() {
    grep -q " $MNT " /proc/mounts 2>/dev/null || { log "unmount: not mounted"; return; }
    sync; umount "$MNT" 2>>"$LOG" && log "unmounted $MNT" || { umount -l "$MNT" 2>>"$LOG"; log "lazy-unmounted $MNT"; }
}

# --- status (written only when it CHANGES, to avoid /media/internal flash wear
#     from a 1 Hz rewrite loop) ---------------------------------------------
json_bool() { [ "$1" = "yes" ] && echo true || echo false; }
LAST_STATUS=""
write_status() {
    otg=$(get_flag otg); [ -n "$otg" ] || otg=peripheral
    power=$(get_flag power); [ "$power" = "on" ] || power=off
    dev=$(storage_dev); present=no; mounted=no
    [ -n "$dev" ] && present=yes
    grep -q " $MNT " /proc/mounts 2>/dev/null && mounted=yes
    s=$(printf '{"otg":"%s","power":"%s","storage":{"present":%s,"mounted":%s,"dev":"%s","mountpoint":"%s"}}' \
        "$otg" "$power" "$(json_bool $present)" "$(json_bool $mounted)" "$dev" "$MNT")
    [ "$s" = "$LAST_STATUS" ] && return          # unchanged -> no write
    LAST_STATUS="$s"
    tmp="$STATUS.tmp.$$"
    echo "$s" > "$tmp"; mv -f "$tmp" "$STATUS" 2>/dev/null
}

# --- main loop ----------------------------------------------------------------
log "started (pid $$)"
ensure_debugfs
# OTG mode does NOT survive a reboot (kernel boots in peripheral/gadget mode),
# so always reset our OTG flag to match reality on startup. The power flag IS a
# persistent preference (the daemon keeps enforcing it), so leave it as saved.
[ -f "$STATE" ] || echo "power=off" > "$STATE"
set_flag otg peripheral
write_status

while true; do
    if [ -f "$CONTROL" ]; then
        # busybox tr has no POSIX classes -- use explicit whitespace chars.
        cmd=$(tr -d ' \t\r\n' < "$CONTROL" 2>/dev/null); rm -f "$CONTROL"
        case "$cmd" in
            otg-host)        otg_set host ;;
            otg-peripheral)  otg_set peripheral ;;
            power-on)        set_flag power on;  power_apply ;;
            power-off)       set_flag power off ;;
            mount)           storage_mount ;;
            unmount)         storage_unmount ;;
            refresh|"")      : ;;
            *)               log "unknown command: $cmd" ;;
        esac
        write_status
    fi
    # keep high-power devices configured while the mode is on
    [ "$(get_flag power)" = "on" ] && power_apply
    write_status
    sleep 1
done
