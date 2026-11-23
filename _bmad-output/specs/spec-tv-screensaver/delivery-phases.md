# Delivery phases

The order is binding: each phase settles a risk the next one depends on.

| # | Phase | Delivers | Settles |
| --- | --- | --- | --- |
| 1 | TV spike | A bare TV app: `DisplayReport` reading recorded by Kay (`tool/tv/display_report.sh`), 4K HEVC clip in texture vs platform view compared, HDR10/HLG/Dolby Vision clips and 24p frame-rate match checked, 4K image shown, wakelock held for 8 h with Idle TV standby off | Render resolution, video path, HDR, CAP-1 settings |
| 2 | Pi basics | Router reservations, the Pi pinned to Floor 1 at 5 GHz, Avahi, an authenticated Dart file server with Range, a systemd unit enabled at boot. The TV plays a hard-coded playlist from the Pi. Sustained Pi → TV throughput measured (TV app downloads a 1 GB test file; Kay runs it), streaming ceiling set. A power-cut test passes | Streaming over the real LAN (CAP-2), unattended recovery (CAP-11) |
| 3 | Hub on Pi | `hub_core` extracted from drawing_poc, the TV as display client (`display.capabilities`, `player.report`), phone pairing via the QR shown on the TV, owner/controller/display roles, `player` module incl. seek and mute, admin reset CLI | CAP-6, CAP-7 |
| 4 | Library | Phone image prep and resumable uploads, Pi variants/ffprobe worker, playlists, inbox share, TV LRU cache | CAP-3, CAP-4, CAP-5, CAP-8, CAP-9 |
| 5 | Player polish | Pre-buffered next item, crossfade, optional Ken Burns, info overlay on the remote, offline behaviour and resync. **Native 4K image path if phase 1 shows a 1080p render** | CAP-1 soak, CAP-3, CAP-8 |
| 6 | TV updates from the Pi | `update.json` + APK served by the Pi, the TV's update action | CAP-10 |
| 7 | Optional | A 4K still-as-HEVC clip mode | — |

## Tests (beyond the connection spec's list)

- Range: `206` with the right `Content-Range`, a seek in the middle of a file, `401` without a token.
- Resumable upload: interrupted at 40 %, resumed from the `HEAD` offset, sha256 matches. A wrong hash → `422`, partial file deleted. Over the size limit → `413`.
- Pairing relay: `devices.startPairing` → the code shown via `display.pairing` is single use and rotates. The first phone becomes owner, the TV stays `display`.
- Capabilities: an item whose codec or HDR format is missing from `display.capabilities` is rejected; one above the streaming ceiling plays only once cached.
- Offline: the Pi stops → the TV loops cached items and the remote still works. The Pi returns → the TV's `player.report` is adopted, no jump. Phone `player.*` with no display → `unavailable`.
- Fidelity: rotated JPEG and Display P3 JPEG uploaded without re-encode, ICC and orientation kept, GPS gone.
- Recovery: hold Back 10 s → "Forget all phones" → old phone tokens get `401`, the next phone becomes owner. A wiped TV is approved by a controller phone; with no phone paired it is accepted directly. `tvsaver admin reset-pairings` → all tokens get `401`, TV and phone pair again.
- Soak: 8 h on the X90K, memory sampled hourly, no growth trend.
