# Home network setup: address reservations and one Wi-Fi (AP mode)

Goal: one network, one Wi-Fi name, fixed addresses for the TV and the Pi.
Values below were read from the devices on 2026-11-23.

## 1. Devices

| Device | Network | MAC (reserve this) | IP to reserve | Notes |
|---|---|---|---|---|
| Pi 5 `gemini-pi` | `LightSpeed_Auto_Floor_1` | `2C-CF-67-0B-EF-F9` | `192.168.0.43` | Hardware MAC, no randomization. `tvsaver` on port 8772. |
| Sony X90K TV | `LightSpeed_Auto_Floor_1` | `38-B8-00-3F-CE-58` | `192.168.0.24` | Factory MAC. Android also has a randomized MAC `92:0c:4f:23:8c:78` saved. Confirm the router's client list shows `38:B8:00:3F:CE:58` before saving. |
| Floor 1 router (TP-Link AX1500) | | | `192.168.0.1` | Does DHCP. Reservations go here. |
| Floor 2 router (TP-Link AX1500) | `LightSpeed_Auto_Floor_2` | | gets an address from Floor 1 in AP mode | Becomes an access point. |

## 2. Reserve the IPs (Floor 1 router, `http://192.168.0.1` or `http://tplinkwifi.net`)

| Step | Action | Check |
|---|---|---|
| 1 | Log in. Go to Advanced, Network, DHCP Server, Address Reservation. | Page lists current reservations. |
| 2 | Open the client list and compare the TV's MAC with the table above. | Router shows `38:B8:00:3F:CE:58` for the TV. If it shows `92:0C:...`, stop and tell Claude. |
| 3 | Add: MAC `2C-CF-67-0B-EF-F9`, IP `192.168.0.43`, enable, save. | Entry appears in the list. |
| 4 | Add: MAC `38-B8-00-3F-CE-58`, IP `192.168.0.24`, enable, save. | Entry appears in the list. |
| 5 | Reboot the Pi (`sudo reboot`). | Pi returns on `192.168.0.43`, `/health` answers within 2 minutes. |

## 3. Make the Floor 2 router an access point

| Step | Action | Check |
|---|---|---|
| 1 | Log in to the Floor 2 router. Back up its settings first (System, Backup & Restore). | Backup file saved on the PC. |
| 2 | Switch to Access Point mode (Advanced or System, Operation Mode). Let it reboot. | Router restarts. |
| 3 | Move the Ethernet cable from its WAN port to a LAN port. The other end stays in a LAN port on the Floor 1 router. | Link light on. |
| 4 | Set its Wi-Fi to SSID `LightSpeed_Auto_Floor_1` with the same password and security as Floor 1. Use a different channel from Floor 1. | Devices see one Wi-Fi name. |
| 5 | Find its new admin address in the Floor 1 client list, or try `http://tplinkwifi.net`. | Admin page opens. |
| 6 | Connect the desktop to the Wi-Fi. | `ping 192.168.0.43` works, and `ssh allramest@gemini-pi.local` works. |

## 4. After it works (Claude updates)

| Item | Change |
|---|---|
| `lan-setup.md`, `BUILD_AND_DEPLOY.md` | Replace the two-network and double-NAT text with the single network. |
| Pi Wi-Fi fallback | The Floor 2 profile is no longer needed. Decide whether to remove it and the prefer timer. |
| Memory note `home-network-two-routers` | Update to the merged network. |
| `setup_phase2.sh` / `power_cut_test.sh` | Can run from the desktop on any floor. |

## 5. If something goes wrong

| Symptom | Likely cause | Fix |
|---|---|---|
| Pi came back on a different IP | Reservation MAC or IP typo, or lease not renewed | Recheck step 2. Run `sudo nmcli con up LightSpeed_Auto_Floor_1` on the Pi. |
| TV lost its address | TV switched to its randomized MAC | Reserve the MAC the router lists for the TV. Changing the TV setting is Kay's call. |
| Floor 2 router unreachable after AP mode | Its address changed | Find it in the Floor 1 client list, or reset it and restore the backup. |
| No internet on Floor 2 devices | Cable still in the WAN port | Use a LAN port. |
