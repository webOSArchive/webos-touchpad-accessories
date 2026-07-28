# host-tools

Host-side (Linux dev machine) helpers for the TouchPad novacom workflow.

## novacomd Wi-Fi toggle

The host runs a patched `novacomd` (see `../DEVICE-STATE.md`) that can serve a
TouchPad over Wi-Fi (TCP) as well as USB, configured by a systemd drop-in at
`/etc/systemd/system/novacomd.service.d/tcp-device.conf` (`novacomd -c <IP>:6969`).

**Gotcha:** while the Wi-Fi target is unreachable (device off/off-network),
novacomd keeps retrying that TCP address and **USB access gets laggy** — every
failed connect stalls the daemon, and WOSQI installs over USB can time out
mid-way. So switch to USB-only before heavy USB work.

```sh
# Serve a Wi-Fi device (+ USB). Default IP 192.168.10.67 (the dev unit).
./start-novacomd-wifi.sh [DEVICE_IP]

# Drop the Wi-Fi transport; go USB-only and responsive.
./stop-novacomd-wifi.sh
```

Both require `sudo` (they rewrite the systemd drop-in and restart novacomd) and
print `novacom -l` afterward so you can confirm what's connected. The change is
persistent across host reboots until you run the other script.
