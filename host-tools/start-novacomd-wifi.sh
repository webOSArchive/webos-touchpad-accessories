#!/usr/bin/env bash
#
# start-novacomd-wifi.sh [DEVICE_IP]
#
# (Re)configure the host's novacomd to ALSO serve a TouchPad over Wi-Fi (TCP),
# on top of USB. Writes the systemd drop-in and restarts novacomd.
#
#   ./start-novacomd-wifi.sh            # default IP 192.168.10.67
#   ./start-novacomd-wifi.sh 192.168.1.42
#
# Requires sudo. Reverse with stop-novacomd-wifi.sh.
#
# CAVEAT: while the Wi-Fi target is unreachable, novacomd keeps retrying it and
# USB access gets laggy (each failed connect stalls the daemon). Run
# stop-novacomd-wifi.sh when you're done with Wi-Fi, or before heavy USB work.
#
set -euo pipefail

IP="${1:-192.168.10.67}"
PORT="${NOVACOM_TCP_PORT:-6969}"
NOVACOMD="${NOVACOMD:-/usr/local/bin/novacomd}"
DROPDIR=/etc/systemd/system/novacomd.service.d
DROPIN="$DROPDIR/tcp-device.conf"

# rudimentary IPv4 sanity check
case "$IP" in
    *[!0-9.]*|""|*..*) echo "error: '$IP' is not an IPv4 address" >&2; exit 2 ;;
esac

echo ">> configuring novacomd to serve Wi-Fi device ${IP}:${PORT} (+ USB)"
sudo mkdir -p "$DROPDIR"
sudo tee "$DROPIN" >/dev/null <<EOF
[Service]
ExecStart=
ExecStart=${NOVACOMD} -c ${IP}:${PORT}
EOF
sudo systemctl daemon-reload
sudo systemctl restart novacomd

sleep 2
echo ">> novacom devices:"
novacom -l 2>&1 || true
echo ">> done. Target the Wi-Fi device with:  novacom -d tcp ..."
