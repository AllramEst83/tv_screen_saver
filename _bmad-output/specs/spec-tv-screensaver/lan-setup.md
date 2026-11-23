# LAN and device setup (CAP-1, CAP-7)

## Routers (two TP-Link AX1500s, Floor 1 and Floor 2)

- **Address Reservation** (Advanced → Network → DHCP Server → Address Reservation) for the Pi and the TV, on the **Floor 1** router. Optionally, also reserve the Pi on the Floor 2 router, so its fallback address is predictable too. Reserve each device's Wi-Fi MAC. The phone needs no reservation.
- On the TV, use the device MAC (not a randomized one), so the reservation survives rejoining the network.
- The TV and the Pi use the Floor 1 router's **5 GHz** band (streaming headroom for high-bitrate 4K HDR).
- All devices are on the main network. The guest network isolates clients.
- Reservations make the "last known address" reconnect path work almost every time. mDNS and QR stay as fallbacks.

## TV (Sony X90K)

- **Idle TV standby: Off** (Settings → System → Power and energy). Otherwise the TV switches off after 1–4 h without remote input, even while playing.
- Picture power saving / Eco: Off.
- Picture, for accuracy: Picture mode **Custom**, **Motionflow Off**. HDR modes switch automatically.
- Screensaver "when to start": the longest value, as a backup. The app holds `wakelock_plus` while playing.
- The app runs in immersive full-screen and restores the last playlist and position on start.
- Release keystore from day one, backed up (connection spec).
- LCD panel, so burn-in is not a concern.

## Pi (gemini-pi.local)

- Debian 13 aarch64, 8 GB RAM, SSH user `allramest` (key `~/.ssh/id_ed25519_claude`). Docker is empty and not needed.
- Leave the Pi on DHCP with the router reservation. Don't set a static IP on the Pi.
- Admin: `tvsaver admin reset-pairings` over SSH clears all pairings (last-resort recovery; the TV remote's "Forget all phones" covers the usual case).
- Services: `tvsaver` (systemd, the Dart AOT exe), Avahi service file `_tvsaver._tcp` on port 8772, Samba share `inbox`.

### Unattended boot (CAP-11)

- `tvsaver.service`: `WantedBy=multi-user.target` (enabled), `After=network-online.target`, `Wants=network-online.target`, `Restart=always`, `RestartSec=5`, runs as `allramest`. The server binds `0.0.0.0` so it survives an IP change.
- Avahi is enabled (already the case).

### Wi-Fi selection (CAP-11)

**Home layout (temporary, until the networks are merged):** two routers. The Floor 2 router's WAN port is plugged into a LAN port on the Floor 1 router, so there are two separate networks (double NAT).

| Network | SSID | Devices |
| --- | --- | --- |
| Floor 1 | `LightSpeed_Auto_Floor_1` | TV, Pi (production) |
| Floor 2 | `LightSpeed_Auto_Floor_2` | Dev desktop |

- mDNS (`gemini-pi.local`, `_tvsaver._tcp`) doesn't cross the router. Floor 1 devices can't reach Floor 2 at all.
- For TV and Pi work (installs, SSH, deploys), the desktop joins `LightSpeed_Auto_Floor_1` with its Wi-Fi card, so it's on the same network and `gemini-pi.local` resolves. Phones pair and discover on Floor 1.
- On Floor 2 fallback the TV can't reach the Pi. Floor 2 is only good for maintenance access.

Starting point on the Pi: both profiles saved with `autoconnect yes` and priority `0`, so NetworkManager can pick either. Target:

- `LightSpeed_Auto_Floor_1`: `connection.autoconnect-priority 100`, `connection.autoconnect-retries 0` (retry forever). `802-11-wireless.band a` (5 GHz) is set only if the setup scan sees a 5 GHz BSS of Floor 1 with signal >= 40; otherwise the band stays unset and the script warns, so the lock can never strand the Pi.
- `LightSpeed_Auto_Floor_2`: `connection.autoconnect-priority 10`, the fallback when Floor 1 isn't in range at boot.
- Every other Wi-Fi profile: `connection.autoconnect no`.
- **Return to Floor 1:** NetworkManager doesn't re-check priorities while connected. A systemd timer (`tvsaver-wifi-prefer.timer`, every 60 s) does this: if the active profile is Floor 2 and `nmcli dev wifi list --rescan yes` shows Floor 1, run `nmcli con up LightSpeed_Auto_Floor_1`. If that fails, NetworkManager falls back to Floor 2 on its own.
- **Passwords (optional):** if you want the script to set them, put them in `/home/allramest/.config/tvsaver/.env` (`chmod 600`, never committed):
  ```
  WIFI_FLOOR1_SSID=LightSpeed_Auto_Floor_1
  WIFI_FLOOR1_PSK=...
  WIFI_FLOOR2_SSID=LightSpeed_Auto_Floor_2
  WIFI_FLOOR2_PSK=...
  ```
  Without the file, or with an empty PSK, the saved profile password is left untouched. The setup script (`tool/pi/setup_wifi.sh`, run as `sudo bash`, `--dry-run` to preview) sets the priorities, the conditional band lock, optional PSKs and the timer. It's idempotent and never prints the PSKs. The timer runs `/usr/local/lib/tvsaver/wifi_prefer.sh` (root-owned copy) under `flock`, and acts only when Floor 2 is active and a rescan shows Floor 1.
- Check: reboot, then `nmcli -t -f NAME,DEVICE connection show --active` shows Floor 1. Turn off Floor 1 Wi-Fi and reboot → Floor 2. Turn Floor 1 back on → back on Floor 1 within 2 minutes.
- Tools: `ffmpeg`/`ffprobe`, `libvips-tools`, `libsqlite3`.
