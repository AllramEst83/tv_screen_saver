# Build and deploy: TV Saver

One Flutter project, two apps built as Gradle product flavors:

| App | Flavor | Application id | Entry point | Target |
| --- | --- | --- | --- | --- |
| TV (Sony XR-55X90K, Google TV, Android 12, **32-bit ARM**) | `tv` | `com.codedbykay.tvsaver.tv` | `lib/main_tv.dart` | `android-arm` |
| Phone | `phone` | `com.codedbykay.tvsaver` | `lib/main_phone.dart` | phone ABI (section 12) |

Phase 1 (story 1-1) builds the TV app only: a full-screen spike that shows and logs the `DisplayReport` (what the app renders vs what the panel shows). Story 1-2 adds a remote-driven video test screen (section 8).

## 1. Prerequisites

- Flutter stable (built with 3.47) and the Android SDK; check with `flutter doctor`.
- `adb` on your PATH (Android SDK platform-tools).
- First time only: `flutter pub get`.

## 2. Release keystore (already created, back it up)

The keystore was generated when the project was created, with a random password:

- `android/app/upload-keystore.jks` (alias `tvsaver`)
- `android/key.properties` (the passwords; format in `android/key.properties.example`)

Both are git-ignored. **Back up both files now** (password manager plus an offline copy). Without this keystore you can never update the installed app: Android refuses an update signed with a different key, and you would have to uninstall it (losing its data).

If `android/key.properties` is missing, a release build still succeeds but is signed with the **debug key** and Gradle prints a warning. Never install such an APK on the TV for good.

To create a new keystore on another machine (only if the original is truly lost; `keytool` is not on PATH):

```bash
"C:/Program Files/Android/Android Studio/jbr/bin/keytool.exe" -genkeypair -keystore android/app/upload-keystore.jks -storetype PKCS12 -keyalg RSA -keysize 2048 -validity 10000 -alias tvsaver
cp android/key.properties.example android/key.properties   # then fill in the passwords
```

## 3. Versions

`pubspec.yaml` has `version: 0.1.0+1`: the part before `+` is the version name, the number after `+` is the **versionCode**. Increase the versionCode for every release you install over an older one.

## 4. Build the TV APK

From the project root:

```bash
flutter build apk --release --flavor tv --target-platform android-arm -t lib/main_tv.dart
cp build/app/outputs/flutter-apk/app-tv-release.apk build/tv-saver-tv.apk
```

`--target-platform android-arm` is required: the Sony is 32-bit only, and the build strips the other ABIs. The APK is about 12 MB.

## 5. Install on the TV (over ADB)

1. On the TV: Settings, System, About, press "Android TV OS build" seven times; then Settings, System, Developer options: turn on **USB debugging** / network debugging.
2. Connect and install:

   ```bash
   adb connect 192.168.0.24:5555
   adb -s 192.168.0.24:5555 install -r build/tv-saver-tv.apk
   adb -s 192.168.0.24:5555 shell monkey -p com.codedbykay.tvsaver.tv -c android.intent.category.LEANBACK_LAUNCHER 1
   ```

   **TV Saver** appears in the Google TV apps row (banner) and opens full screen.
3. `INSTALL_FAILED_UPDATE_INCOMPATIBLE`: a build signed with another key is installed. `adb uninstall com.codedbykay.tvsaver.tv` and install again (its data is lost).

## 6. Measure the display (DisplayReport)

```bash
tool/tv/display_report.sh 192.168.0.24:5555
```

(Run it from Git Bash on Windows.) It is **read-only**: it installs nothing and changes no TV setting (it never runs `wm size`/`wm density` with arguments or `settings put`). It:

1. connects over adb (exit 1 with `TV not reachable at <ip>` and no file if that fails);
2. looks for the app's `DisplayReport: renders …` line in logcat; if missing, launches the app (restarting it if it was already running) and waits up to 15 s;
3. writes `build/measurements/display-report-<timestamp>.txt` with the DisplayReport line, `wm size`, `wm density`, the display modes and HDR capabilities, and the full `dumpsys display`;
4. prints a summary. Exit 0 when complete, 2 when the app line is missing (the adb sections are still in the file).

The panel size in the line comes from the TV's native display mode (`Display.getMode()`), not from the window size Android reports, because a `wm size` override shrinks the latter. If that read fails, the line ends with `(panel unverified)`: the panel then shows the override, not the real panel, so check it against `wm size` (`Physical size`). If no view appears, the app logs `DisplayReport: unknown` and gives up after 10 frames.

The on-screen report and the log line should match the file. Record the result in the spec memlog (`_bmad-output/specs/spec-tv-screensaver/.memlog.md`).

The app's log line on its own: `adb -s 192.168.0.24:5555 logcat -d -s flutter | grep DisplayReport`.

## 7. Check a build before you ship it

```bash
flutter analyze
flutter test
```

Both must pass with no issues. For a video-spike build also run the release build from section 4 (the APK stays under 25 MB).

## 8. Video path spike (story 1-2)

Question: which video path gives full 4K sharpness, HDR pass-through, native frame rate and a gap-free loop with sound on the X90K? Nothing here changes a TV setting: adb only installs the app and pushes clips into the app's own files dir.

### Generate the clips (PC)

```bash
winget install Gyan.FFmpeg        # once; open a new shell afterwards
bash tool/video/generate_clips.sh
```

Without ffmpeg the script prints the winget command and exits 1 without writing anything. It writes five 10 s clips to `build/spike-media/` (git-ignored): `1-sdr-lines` (HEVC Main10 SDR, 1 px line pairs and gradient), `2-hdr10-lines`, `3-hlg-lines`, `4-pan-23976` (23.976 fps pan), `5-loop-audio` (AAC stereo noise bursts at every whole second, one starting exactly at the loop point, and a frame counter). Dolby Vision is not part of this story.

### Push and run

```bash
# build and install as in sections 4 and 5, then:
bash tool/video/push_clips.sh 192.168.0.24:5555
```

`push_clips.sh` reads the free space first (`df`), refuses clips totalling more than 1.5 GB or leaving less than 300 MB spare, pushes to `/sdcard/Android/data/com.codedbykay.tvsaver.tv/files/spike/` and prints the free space before and after. With no clips pushed the spike screen tells you the command.

On the TV, open TV Saver, press **OK** on the report screen to open the **Video spike**. Remote only: Up/Down moves, OK changes a setting row or plays a clip, Back stops (in a clip) or leaves. Rows:

- **View**: `texture` (video_player, Flutter texture), `platform-view` (video_player, `VideoViewType.platformView`), `media3-surface` (native Media3 ExoPlayer on a SurfaceView platform view).
- **Loop**: `repeat-one` or `two-item-playlist` (two items of the same clip, repeat-all). `video_player` cannot do a playlist, so the playlist loop always uses the Media3 view.

In the texture and platform-view (video_player) modes the logged `decoder=` is the one MediaCodecList predicts; the media3-surface mode reports the decoder actually in use.

An overlay shows clip, mode, display mode, HDR type, decoder and dropped frames (Media3 only; `video_player` does not expose them). OK hides or shows it (hide it before judging the picture). A clip that cannot be decoded shows `cannot play: <reason>`.

### Read the log

```bash
adb -s 192.168.0.24:5555 logcat -d -s flutter | grep VideoSpike
```

At startup: `VideoSpike: decoder <name> <mime> hw=... profiles=[...]` for every HEVC, AC-3, E-AC-3 decoder. Per run, 4 s after the clip starts and again when you press Back: `VideoSpike: clip=..., mode=..., loop=..., phase=playing|stopped, decoder=..., hdr=..., display_before=WxH@Hz, display_now=WxH@Hz, dropped=N|n/a[, result=...]`. `phase=failed` carries `note=cannot play: ...`.

### How to judge each clip, and where to record it

Append every finding as a `note` entry in `_bmad-output/specs/spec-tv-screensaver/.memlog.md`, with the matching `VideoSpike:` line.

| Clip | Do | Record |
| --- | --- | --- |
| 1 sdr-lines | Play in `texture`, then `platform-view`, then `media3-surface` (overlay hidden, sit close). | Which view shows the 1 px lines and the checkerboard as crisp black/white (not grey, not blurred); the winner of texture vs SurfaceView. |
| 2 hdr10, 3 hlg | Play each in `platform-view` and `media3-surface`. | `hdr=` in the log, and whether the TV shows its HDR badge or switches picture mode. |
| 4 pan-23976 | Play once with the TV's "Match content frame rate" off, once on (change it by hand; the app and scripts never do). | `display_before` / `display_now`, `result=24p possible` or `only 60 Hz mode`, and whether the pan judders. The TV reported only 3840x2160@60 in story 1-1, so `only 60 Hz mode` is the expected result. |
| 5 loop-audio | Play with `repeat-one` in `platform-view`, `repeat-one` in `media3-surface`, then `two-item-playlist`. Watch the frame counter and listen for the noise burst at the loop point (a burst at the start of every second, including the first of each loop). | Per strategy: audible gap or click at the loop, black or repeated frame at the loop; which strategy is gap-free. |

If 24p is impossible or HDR or the loop fail, CAP-2's success text needs a decision from Kay; this story only records the outcome.

Read-only checks that do not need the spike: `tool/tv/display_report.sh` (section 6).

## 9. Pi Wi-Fi pinning (story 2-1)

Pins the Pi to `LightSpeed_Auto_Floor_1` (priority 100, 5 GHz only if safe), keeps Floor 2 as the fallback and installs a timer that returns the Pi to Floor 1 within 2 minutes of it reappearing. Privileged steps run on the Pi by you with `sudo`; the PC side only copies files and reads state.

**Which address to use.** The PC is on Floor 2. Once pinned, the Pi is on Floor 1 and `gemini-pi.local` may not resolve. Use `PI_HOST=<Pi's Floor 1 IP>` (find it in the Floor 1 router's DHCP list; the PC reaches Floor 1 addresses by IP, like the TV). If the Pi seems unreachable it is probably still on Floor 2: try `192.168.1.207`.

```bash
# PC (Git Bash). PI_HOST defaults to gemini-pi.local; use the IP if it does not resolve.
PI_HOST=192.168.1.207 bash tool/pi/deploy.sh       # scp only, no sudo
PI_HOST=192.168.1.207 bash tool/pi/check_wifi.sh   # read-only status, no passwords

# On the Pi (ssh in):
sudo bash ~/tvsaver/pi/setup_wifi.sh --dry-run     # preview
sudo bash ~/tvsaver/pi/setup_wifi.sh               # apply; a second run says "no changes"
```

Good to know:
- Setup turns autoconnect off on every other Wi-Fi profile. Undo one with `sudo nmcli connection modify <name> connection.autoconnect yes`.
- Disable the timer with `sudo systemctl disable --now tvsaver-wifi-prefer.timer`.
- Priority changes apply at the next reconnect, so a Pi that is on Floor 2 stays there until the timer fires (within 60 s) or it reboots.
- Passwords are optional. To have the script set them, copy `~/.config/tvsaver/.env.example` to `.env`, fill it in and `chmod 600` it. Never commit it.

Offline test of the scripts (fake `nmcli`): `bash tool/pi/test/test_wifi_scripts.sh`.

Reboot tests, after the setup (report each `check_wifi.sh` output):
1. Floor 2 stronger at the Pi, reboot. Pass: `check_wifi.sh` shows Floor 1 active (5 GHz if it was eligible). Fail: Floor 2 active.
2. Floor 1 Wi-Fi off, reboot. Pass: `check_wifi.sh` shows Floor 2 active. Fail: no Wi-Fi.
3. Turn Floor 1 back on. Pass: Floor 1 active within 2 minutes (`journalctl -u tvsaver-wifi-prefer -n 5` shows the switch). Fail: still Floor 2 after 2 minutes.

## 10. Pi file server (story 2-2)

A pure-Dart HTTP server (`packages/hub_core`, entry `bin/pi_server.dart`) on port 8772: `GET /health` (no auth) and `GET|HEAD /media/<id>/full` with `Range`/`206`, bearer token required. Media lives in `~/tvsaver/media/<id>` on the Pi. Multi-range requests are ignored (full `200`). Traffic — including the `Authorization: Bearer` header — is **plain HTTP on the home LAN** (no TLS by design); never expose port 8772 outside the LAN.

Since story 3-1 the same listener is a `HubServer` (WebSocket `/ws` transport), and the media routes are mounted into it. Story 3-2 adds the `DevicesModule`: pairing, roles and recovery (see "Pairing, roles and recovery" below). The hub id and settings are in memory (`MemoryTvStore`) until later stories. Devices and pairings live in SQLite (`TVSAVER_DB_FILE`, default `~/tvsaver/hub.db`) through drift, using the system SQLite runtime library (`libsqlite3.so.0`, from `libsqlite3-0`; the unversioned `libsqlite3.so` is not needed). If the port is busy the server exits with code 1. After changing the drift tables, regenerate the database code: `(cd packages/hub_core && dart run build_runner build --delete-conflicting-outputs)`. Check the build with `dart compile exe bin/pi_server.dart -o build/pi_server_check`.

The static bearer token stays for scripts and the admin CLI; the media routes also accept the token of any paired device (so the TV streams with its own token): the first run creates `~/.config/tvsaver/token` (random 32-byte hex, mode `0600`; override with `TVSAVER_TOKEN_FILE`). Other overrides: `TVSAVER_MEDIA_DIR`, `TVSAVER_PORT`, `TVSAVER_ID`.

```bash
# PC (Git Bash). Use the Pi's reachable address in PI_HOST (Floor 1 IP while the PC is on Floor 1).
(cd packages/hub_core && dart analyze && dart test)
PI_HOST=<pi-ip> bash tool/pi/deploy_server.sh   # cross-compile linux-arm64, scp, atomic mv, restart via pkill (no sudo)

# On the Pi, once (Kay):
sudo bash ~/tvsaver/pi/install_server.sh --dry-run
sudo bash ~/tvsaver/pi/install_server.sh        # tvsaver.service + Avahi _tvsaver._tcp; idempotent

# PC, after the server runs:
PI_HOST=<pi-ip> bash tool/pi/smoke_test.sh      # real-Pi checks; makes and removes smoke-* files in ~/tvsaver/media
```

Good to know:
- **Read the token** (on the Pi): `cat ~/.config/tvsaver/token`. Never commit it or pass it in URLs.
- **Rotate the token** (on the Pi): `rm ~/.config/tvsaver/token && pkill -x dart:tvsaver` (systemd relaunches within ~5 s and generates a fresh `0600` token).
- **Later deploys & rollback**: run `deploy_server.sh` again; it saves the previous binary as `~/tvsaver/bin/tvsaver.prev`, signals the running server so systemd relaunches within ~5 s, and polls `/health` for up to 15 s. To roll back on the Pi: `mv -f ~/tvsaver/bin/tvsaver.prev ~/tvsaver/bin/tvsaver && pkill -x dart:tvsaver`.

### Pairing, roles and recovery (story 3-2)

- **Roles:** the TV is the `display` (never owner; its requests count as owner-equivalent). The first paired phone is `owner`, later phones are `controller`. Connection cap: 1 display plus up to `maxClients-1` phones (8 connections by default, so 7 phones); the next phone gets `err conflict`.
- **First display:** while no display is paired, the first TV that says `hello {kind: "display"}` is accepted without a PIN and gets a token. A second TV while the first is connected gets `err conflict`.
- **New or wiped TV:** if a display is already paired but offline and at least one phone is paired, the new TV waits up to 120 s for any paired phone to send `devices.approveDisplay {requestId}`; on timeout it gets `err timeout`. If no phone is paired, the new TV is accepted and replaces the old display.
- **Phone pairing:** the TV sends `devices.startPairing`; the Pi then streams `display.pairing {qr, pin, expiresAt}` to the TV on every rotation and after each pairing (`devices.cancelPairing` stops it). Codes are single use and last 120 s; 3 wrong tries lock pairing for 60 s. A phone that tries to pair while no session is open gets `err unavailable`.
- **Owner phone lost:** on the TV send `devices.forgetAll` (the owner can too). All phone pairings are deleted and their sockets closed; the TV stays connected and the next phone to pair is owner. A controller gets `err forbidden` for `devices.forgetAll`.
- **Threat model:** while no display is paired, or no phone is paired, any host on the LAN can claim the display role. This is accepted because physical presence is the only proof left; it is for a home LAN only.
- **Last resort, over SSH on the Pi:**

```bash
~/tvsaver/bin/tvsaver admin reset-pairings
```

  Deletes every device (TV and phones). If the server is running, the CLI asks it over loopback (`POST /admin/reset-pairings` on 127.0.0.1 with the static token; other peers get `403`, a wrong token `401`) and all sockets are closed. If it is not running, the CLI deletes the rows in the database file directly. It prints a short message and exits 1 on failure (wrong token, missing database file). Afterwards the next TV is the first display and the next phone is owner.

Reboot test (after the first install):
- Reboot the Pi (`sudo reboot`).
- **Pass:** within 2 minutes, `curl http://<pi-ip>:8772/health` returns `200` with `"ok":true`, `systemctl is-active tvsaver` prints `active`, and `avahi-browse -rt _tvsaver._tcp` lists `TV Saver on gemini-pi` on port 8772.
- **Fail:** `/health` does not answer within 2 minutes, `tvsaver` is inactive/failed (`journalctl -u tvsaver -n 30`), or `_tvsaver._tcp` is missing from `avahi-browse`.

## 11. TV plays from the Pi, throughput & power-cut test (story 2-3)

Streams the 5 spike clips over LAN HTTP (`Authorization: Bearer`, Media3 `SurfaceView`), measures sustained Pi → TV Wi-Fi throughput with an in-memory 1 GiB download (60 % ceiling), and verifies unattended power-cut recovery. Nothing here changes any TV setting.

### Stage clips, 1 GiB file, and `pi_config.json`

Make sure the TV APK from sections 4–5 is installed (`INTERNET` + `usesCleartextTraffic`), the spike clips exist (`bash tool/video/generate_clips.sh`), and `tvsaver` is running on the Pi. Then from Git Bash on the Floor 1 desktop:

```bash
PI_HOST=192.168.0.43 bash tool/pi/setup_phase2.sh 192.168.0.24:5555
```

`setup_phase2.sh` copies `build/spike-media/[1-5]-*.mp4` and creates a 1 GiB sparse `throughput-1g.bin` in `~/tvsaver/media/` on the Pi, reads `~/.config/tvsaver/token` silently over SSH, and pushes `pi_config.json` into `/sdcard/Android/data/com.codedbykay.tvsaver.tv/files/pi_config.json` (token never printed).

### Play the Pi playlist & run the 1 GiB throughput benchmark

On the TV, open **TV Saver**:
- Press **OK** to open **Pi stream & throughput** (`Right` still opens the local **Video spike**).
- Select **Play Pi playlist**: streams all 5 clips in a loop via Media3 `SurfaceView`. **Left / Right** switches clips, **OK** toggles the overlay (clip, decoder, HDR, dropped frames, position), **Back** stops.
- Select **Run 1 GiB throughput test**: streams `/media/throughput-1g.bin/full` into memory (zero TV flash writes), displays live MB/s & Mbps, and logs the final Mbps and 60 % ceiling. **Back** cancels cleanly.

Read the TV logs and record the throughput figures in `_bmad-output/specs/spec-tv-screensaver/.memlog.md`:

```bash
adb -s 192.168.0.24:5555 logcat -d -s flutter | grep -E 'PiThroughput|PiStream'
```

### Power-cut test (CAP-11)

While the TV is streaming the Pi playlist, run from Git Bash:

```bash
PI_HOST=192.168.0.43 bash tool/pi/power_cut_test.sh
```

Follow the prompts to pull and restore Pi power. Pass criteria:
- TV displays `Reconnecting…` during the outage and auto-resumes playback when the Pi returns (`PiStream: disconnected` / `reconnected`).
- `/health` answers `200` within 120 s of power restore.
- Pi rejoins `LightSpeed_Auto_Floor_1` (not Floor 2), `tvsaver.service` is `active`, and `avahi-browse -rt _tvsaver._tcp` lists port 8772.

## 12. Phone app and pairing with the fake display (story 3-3)

The phone app finds the Pi, pairs by QR code (PIN as fallback), reconnects on its own and shows its role and the paired devices. Android only.

### Build and install

```bash
flutter build apk --debug --flavor phone -t lib/main_phone.dart
adb devices                       # the phone, USB debugging on
adb -s <phone-serial> install -r build/app/outputs/flutter-apk/app-phone-debug.apk
```

For a release build: `flutter build apk --release --flavor phone -t lib/main_phone.dart` (all phone ABIs; signed like the TV app).

The phone must be on the same Wi-Fi as the Pi (Floor 1, see `NETWORK_SETUP.md`). It asks for the camera on the first scan. If you denied it, the scan screen has an "Open settings" button.

### Pair without the TV app: fake display

The TV app has no pairing screen yet. `fake_display.dart` stands in for the TV: it connects to the Pi as a display, opens a pairing session and prints the `tvsaver://pair?...` URI, an ASCII QR code and the PIN. It reprints on every rotation (and after each pairing).

```bash
cd packages/hub_core
dart run tool/fake_display.dart                    # gemini-pi.local:8772
dart run tool/fake_display.dart 192.168.0.43:8772  # explicit address
```

The display token is kept in `.fake_display_token` (current directory, git-ignored) so a second run reconnects as the same display. Delete it to join as a new display, which a Pi with a paired display refuses unless a phone approves. Ctrl+C closes the pairing session.

Use a dark terminal with a large enough window; the QR is drawn with half blocks. On the phone: Scan QR, point at the terminal. The first phone becomes `owner`. If the code was used or expired, the phone asks for the PIN printed under the QR; 3 wrong tries lock pairing for a while.

### Check reconnect

1. Close the phone app and open it again: it goes straight to the connected screen (no scan).
2. Restart the Pi (`sudo systemctl restart tvsaver`): the phone shows "TV not found" or looks for the Pi, then returns by itself.
3. "Forget this Pi" on the phone removes only the pairing on the phone. The Pi still lists the device until the owner or the TV forgets it.

### TV APK size gate

The phone plugins (`mobile_scanner` with bundled ML Kit, `flutter_secure_storage`) are in the shared `pubspec.yaml`, so they ship in the TV APK too. Measure after any dependency change:

```bash
flutter build apk --release --flavor tv -t lib/main_tv.dart --target-platform android-arm
ls -l build/app/outputs/flutter-apk/app-tv-release.apk
```

The TV manifest removes the CAMERA permission the scanner plugin merges in. Check the release TV APK has none (`aapt` is in the Android SDK `build-tools/<version>/` folder; the command prints nothing and exits 1 when the permission is absent):

```bash
aapt dump permissions build/app/outputs/flutter-apk/app-tv-release.apk | grep CAMERA
```

Story 3-3: 13,784,172 bytes before, 19,409,444 after (+5.4 MiB, limit +8 MB).
