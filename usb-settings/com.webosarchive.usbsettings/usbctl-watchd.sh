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
WATCH=/media/internal/.usbctl-watch          # app keepalive: run the device monitor while fresh
DEVICES=/media/internal/.usbctl-devices      # device monitor -> app (JSON list)
USBDEVMON=/usr/bin/usbdevmon
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

# One-shot ARM of the OTG controller (validated 2026-07-29 on a stock device):
# writing "host" ONCE flips a persistent controller state -- from then on (even
# across reboots) the port follows the ID pin: OTG cable in -> host mode +
# enumerate (~0.6s), cable out -> peripheral/gadget. A NEVER-armed device, by
# contrast, hard-hangs its USB port on OTG cable insert until reboot. So arming
# early is a safety fix, not just convenience. We arm only when the port is
# IDLE (no PC/charger gadget connection) because the write force-switches to
# host and would kill an active novacom/charge session mid-use.
arm_otg_once() {
    [ "$(get_flag armed)" = "yes" ] && return
    hc=$(cat /sys/devices/platform/usb_gadget/host_connected 2>/dev/null)
    [ "$hc" = "1" ] && return                   # PC connected: try again later
    [ -d /sys/bus/usb/devices/usb1 ] && { set_flag armed yes; return; }  # already host
    ensure_debugfs
    if echo host > "$OTG" 2>/dev/null; then
        set_flag armed yes
        log "OTG armed (one-shot, persists across reboots)"
    fi
}

# High-power mode: the root hub budgets ~390mA and rejects a config that asks
# for more. Force config 1 on any attached-but-unconfigured device. While the
# flag is on, we re-apply it each loop so freshly-plugged devices get configured
# too. An unconfigured device reads bConfigurationValue as "0" (e.g. a DS4) OR as
# EMPTY (e.g. a DragonRise pad the kernel rejected outright) -- handle both, and
# skip anything already configured ("1"+).
power_apply() {
    for cv in /sys/bus/usb/devices/*/bConfigurationValue; do
        [ -e "$cv" ] || continue
        cur=$(cat "$cv" 2>/dev/null)
        [ "$cur" = "0" ] || [ -z "$cur" ] || continue
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

# Full OTG reset -- the "last resort" unwedge. A USB device can enumerate but
# stop delivering input (interrupt-endpoint wedge from suspend/power churn);
# cycling OTG peripheral->host tears the bus down and re-enumerates everything.
# REFUSED while storage is mounted (the cycle would yank the drive mid-use);
# the app also disables the button then, but guard here too.
reset_usb() {
    grep -q " $MNT " /proc/mounts 2>/dev/null && { log "reset refused: storage mounted"; return; }
    ensure_debugfs
    log "USB reset: OTG cycle begin"
    echo peripheral > "$OTG" 2>/dev/null; set_flag otg peripheral; write_status
    sleep 3
    echo host > "$OTG" 2>/dev/null;       set_flag otg host
    sleep 1
    [ "$(get_flag power)" = "on" ] && power_apply
    log "USB reset: done (host mode restored)"
}

# --- device monitor (usbdevmon) lifecycle ------------------------------------
# Runs only while the app panel is open, gated on the WATCH keepalive file the
# app refreshes (~every poll). Kept off otherwise so it never reads input nodes
# while a game is running (it reads SHARED/no-grab anyway, but off is cleaner and
# avoids needless USB churn -- churn is what wedges devices in the first place).
DEVMON_PID=""
devmon_running() { [ -n "$DEVMON_PID" ] && kill -0 "$DEVMON_PID" 2>/dev/null; }
devmon_start() {
    devmon_running && return
    [ -x "$USBDEVMON" ] || { log "devmon: $USBDEVMON missing"; return; }
    "$USBDEVMON" >/dev/null 2>&1 &
    DEVMON_PID=$!
    log "devmon started (pid $DEVMON_PID)"
}
devmon_stop() {
    devmon_running && { kill "$DEVMON_PID" 2>/dev/null; log "devmon stopped"; }
    DEVMON_PID=""
    rm -f "$DEVICES" 2>/dev/null
}
# app is "watching" if it refreshed the keepalive within the last few seconds
watch_fresh() {
    WF_WT=$(cat "$WATCH" 2>/dev/null); WF_NOW=$(date +%s 2>/dev/null)
    [ -n "$WF_WT" ] && [ -n "$WF_NOW" ] && \
        [ $((WF_NOW - WF_WT)) -ge 0 ] 2>/dev/null && [ $((WF_NOW - WF_WT)) -lt 6 ] 2>/dev/null
}

# --- status (written only when it CHANGES, to avoid /media/internal flash wear
#     from a 1 Hz rewrite loop) ---------------------------------------------
json_bool() { [ "$1" = "yes" ] && echo true || echo false; }
LAST_STATUS=""
write_status() {
    # OTG state comes from the HARDWARE every time, not our saved flag: the
    # controller flips modes on its own on cable/ID-pin events (charger vs OTG
    # cable), so the flag goes stale. The mode knob is write-only (EINVAL on
    # read); the root hub /sys/bus/usb/devices/usb1 exists exactly while the
    # host controller is registered, i.e. host mode. Keep the flag synced so
    # toggles behave consistently.
    if [ -d /sys/bus/usb/devices/usb1 ]; then otg=host; else otg=peripheral; fi
    [ "$otg" = "$(get_flag otg)" ] || set_flag otg "$otg"
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
rm -f "$WATCH" "$DEVICES" 2>/dev/null    # clear stale keepalive/monitor state
ensure_debugfs
# OTG state is probed from the hardware inside write_status (the controller
# flips modes on its own on cable events, so a saved flag would lie). The power
# flag IS a persistent preference (the daemon keeps enforcing it), so leave it.
[ -f "$STATE" ] || echo "power=off" > "$STATE"
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
            reset)           reset_usb ;;
            refresh|"")      : ;;
            *)               log "unknown command: $cmd" ;;
        esac
        write_status
    fi
    # Arm the OTG controller once, at the first moment the port is idle.
    arm_otg_once
    # Keep high-power devices configured while that mode is on. (We do NOT
    # force-config while merely watching: the controller stall is the HID
    # interrupt endpoint failing to bind an input node, not a config problem --
    # config already reads 1. Forcing config fought the wrong layer; the device
    # monitor instead surfaces the detected-but-input-less device directly.)
    [ "$(get_flag power)" = "on" ] && power_apply
    # run the device monitor only while the app panel is open (keepalive fresh)
    if watch_fresh; then devmon_start; else devmon_stop; fi
    write_status
    sleep 1
done
