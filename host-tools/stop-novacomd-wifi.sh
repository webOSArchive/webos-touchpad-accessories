#!/usr/bin/env bash
#
# stop-novacomd-wifi.sh
#
# Restart the host's novacomd USB-only, dropping the Wi-Fi (TCP) transport.
# Use this when the Wi-Fi device is off/unreachable so USB stays responsive --
# otherwise novacomd stalls retrying the dead TCP target and USB access crawls
# (and WOSQI installs over USB can time out mid-way).
#
# Requires sudo. Re-enable Wi-Fi with:  ./start-novacomd-wifi.sh [DEVICE_IP]
#
set -euo pipefail

DROPIN=/etc/systemd/system/novacomd.service.d/tcp-device.conf

if [ -f "$DROPIN" ]; then
    echo ">> removing Wi-Fi drop-in $DROPIN"
    sudo rm -f "$DROPIN"
    sudo systemctl daemon-reload
else
    echo ">> no Wi-Fi drop-in present; just recycling novacomd"
fi
sudo systemctl restart novacomd

sleep 2
echo ">> novacomd is now USB-only. Devices:"
novacom -l 2>&1 || true
