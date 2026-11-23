---
id: SPEC-tv-screensaver
companions:
  - architecture.md
  - media-fidelity.md
  - media-server.md
  - modules.md
  - lan-setup.md
  - delivery-phases.md
  - ../../../phone-tv-connection-consolidated.md
sources:
  - ../../../screensaver-approach.md
---

> **Canonical contract.** This SPEC and the files in `companions:` are the complete, preservation-validated contract for what to build, test, and validate. Source documents listed in frontmatter are for traceability — consult them only if you need narrative rationale or prose color this contract intentionally omits.

# TV Saver

## Why

A vision to realize: turn the Sony 4K TV into an always-on display for long-running videos and high-resolution images, with the best picture the panel can produce, chosen and managed from a phone. The TV has only ~4 GB for apps, so the library lives on a Raspberry Pi 5 on the home LAN, and the TV streams from it. It is built on the proven phone ↔ TV connection layer (`phone-tv-connection-consolidated.md`), with the Pi taking the hub role.

## Capabilities

- **CAP-1**
  - **intent:** The TV shows the chosen playlist full-screen indefinitely, without the Google TV screensaver or idle standby interrupting it.
  - **success:** With the TV settings in `lan-setup.md` applied, an 8-hour unattended run plays without the screensaver, Ambient Mode or standby appearing, and with no memory growth trend (hourly samples).
- **CAP-2**
  - **intent:** The TV plays 4K and HDR video streamed from the Pi at the panel's full resolution, dynamic range, with the video's own sound at its native frame rate (no conversion).
  - **success:** A looping fireplace video plays its sound with no gap at the loop point. A 3840×2160 HEVC test clip with 1 px detail plays at full sharpness (side-by-side with the texture path, per `media-fidelity.md`). HDR10, HLG and Dolby Vision clips switch the TV into the matching HDR mode. A 23.976 fps pan clip shows no objectionable judder, checked by eye (the X90K exposes only a 60 Hz mode, so the app cannot switch the refresh rate). Seeking to the middle of a 10 GB file starts playback within 3 s.
- **CAP-3**
  - **intent:** The TV shows high-resolution images at the panel's full 4K resolution, with their colours intact, without stalls or out-of-memory errors.
  - **success:** The X90K's render vs panel size is recorded by `DisplayReport`. The test chart in `media-fidelity.md` resolves at 3840×2160 on the panel (through the native 4K image path if Flutter renders at 1080p). A Display P3 test image shows the same colours as on the source device. A 30-minute slideshow of 24 MP photos has no OOM or decode stall.
- **CAP-4**
  - **intent:** A paired phone adds photos and videos to the Pi library, without quality loss beyond what `media-fidelity.md` allows.
  - **success:** An image upload meets the fidelity rules (≤ 4096 px, at most one encode, ICC profile and orientation kept, other metadata stripped). A 4 GB video upload interrupted at 40 % resumes and finishes with a matching sha256. A duplicate is detected before transfer.
- **CAP-5**
  - **intent:** A paired phone browses the library and creates, edits and deletes playlists while the TV is off or the TV app is closed.
  - **success:** With the TV off, the phone creates a playlist. When the TV app opens, it shows that playlist with no further action.
- **CAP-6**
  - **intent:** The phone and the TV remote control playback (play a playlist, next, previous, pause, resume, seek, mute), and every connected phone shows what is playing.
  - **success:** A command from either the phone or the remote changes the picture within 1 s. A second phone shows the change within 1 s, and both phones show the same position.
- **CAP-7**
  - **intent:** The phone and the TV pair with the Pi once, and find it again after a dropped connection or an IP change.
  - **success:** The phone pairs by scanning the QR code shown on the TV. After the Pi's IP changes, both the phone and the TV reconnect with no user action (connection spec CAP-3 rules). With the owner phone lost, "Forget all phones" from the TV remote lets a new phone pair as owner. With the TV wiped and no phone paired, the TV pairs again with no other device. After `tvsaver admin reset-pairings` on the Pi, everything pairs again from scratch.
- **CAP-8**
  - **intent:** The TV keeps playing when the Pi is unreachable.
  - **success:** With the Pi stopped, the TV keeps looping the cached items of the current playlist, and the remote still works. When the Pi returns, the Pi adopts the TV's current item and position: the picture does not jump or restart.
- **CAP-9**
  - **intent:** Large video files and images can be added to the library from the PC without the phone.
  - **success:** A file copied into the Pi's inbox share appears in the library with its poster and metadata, and the phones receive the `library.added` event. An image passes the same fidelity rules as a phone upload.
- **CAP-10**
  - **intent:** The TV app updates itself over the LAN from the Pi.
  - **success:** After a new APK is put on the Pi, the TV finds the new version, downloads it, verifies its sha256 and opens the Android installer (connection spec CAP-10, with the Pi as the host).
- **CAP-11**
  - **intent:** The Pi recovers on its own after a reboot or power cut: it joins the TV's network (`LightSpeed_Auto_Floor_1`), falls back to `LightSpeed_Auto_Floor_2` only when Floor 1 can't be found, returns to Floor 1 when it reappears, and starts the server.
  - **success:** After pulling the Pi's power and restoring it, without anyone touching it, the Pi is on Floor 1 even though Floor 2 is stronger, `/health` answers within 2 minutes, and the phone and the TV reconnect. With Floor 1 off at boot, the Pi joins Floor 2. Within 2 minutes of Floor 1 returning, it's back on Floor 1.

## Constraints

- Picture quality wins every trade-off: no re-encode when one can be avoided, no downscale below the panel, no colour-profile loss, no frame-rate conversion in the app (`media-fidelity.md`).
- The Pi is authoritative for the library, playlists, pairings and settings. The TV is authoritative for what is on screen: the current item and position, which the Pi adopts on every reconnect. This replaces "the TV is authoritative" from the connection spec. Every other rule from it applies unless `architecture.md` overrides it.
- Pairing needs physical presence: the Pi has no screen, so the QR code and PIN only appear on the paired TV.
- The server code is pure Dart (no Flutter imports), so the same code runs on the Pi as an AOT executable and is shared with the apps.
- TV: Sony XR-55X90K, Google TV / Android 12, 32-bit ARM only, weak CPU, ~4 GB app storage. The TV-side cache stays within a fixed cap (`media-server.md`).
- Video never goes through a Flutter texture when a SurfaceView path is available. On the X90K, the UI plane may be 1080p (`media-fidelity.md`).
- The Pi does no video transcoding (the Pi 5 has no hardware encoder). Videos are prepared on the PC or uploaded as they are when the TV can decode them.
- The Pi runs unattended: the server starts at boot, waits for the network and restarts on failure. Network choice is fixed by configuration, never by signal strength (`lan-setup.md`).
- The TV and the Pi are on Wi-Fi only. There is no fixed bitrate cap: a video above the measured streaming ceiling plays only once it is fully cached on the TV (`media-server.md`).
- Media is stored on the Pi's 128 GB SD card. The library cap defaults to 90 GB.
- LAN only, no cloud. App name "TV Saver", Android ids `com.codedbykay.tvsaver` (phone) and `com.codedbykay.tvsaver.tv` (TV). mDNS `_tvsaver._tcp`, port 8772, QR scheme `tvsaver://`.
- Media is served over HTTP with `Range` support and a bearer token. Tokens never appear in URLs (`media-server.md`).

## Non-goals

- An OS-level screensaver (Android `DreamService`). The app is a normal full-screen app.
- Turning the TV on or off from the Pi or the phone (BRAVIA IP control, ADB, schedules). The user powers the TV manually.
- Video transcoding on the Pi.
- HDR stills: Ultra HDR gain maps are dropped and images render SDR in v1.
- Internet or remote access, cloud storage, accounts.
- Live gesture control (connection spec CAP-6 hot frames), unless a later spec adds phone-driven pan/zoom.
- iOS phones, web clients, non-Android TVs.

## Success signal

- The user scans one QR code on the TV to pair a phone, uploads a 4K HDR video and a set of photos, and builds a playlist while the TV is off. They turn the TV on, open the app, and the playlist plays in 4K HDR at its native frame rate all evening without the screensaver or standby. Unplugging the Pi doesn't stop the picture.

## Assumptions

- The drawing_poc reference implementation (`../drawing_poc`: `lib/lan`, `lib/tv/server`, `lib/tv/update`, `lib/tv/display_report.dart`, `lib/phone/images/image_prep.dart`) is copied and adapted, not depended on.
- The X90K's 1080p UI plane is unverified until Kay records the `DisplayReport` reading in phase 1.
- The X90K's Wi-Fi sustains well above 50 Mbps from the Pi. Kay measures the real figure in phase 2 with the TV app's 1 GB download test.

## Open Questions

- None. The `DisplayReport` reading (phase 1) and the Wi-Fi throughput (phase 2) are measurements, not decisions; their results are logged when taken.
