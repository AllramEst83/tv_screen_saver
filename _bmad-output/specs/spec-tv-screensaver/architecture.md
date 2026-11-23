# Architecture (CAP-5 – CAP-8)

## Topology

```
          ┌──────────── Raspberry Pi 5 · gemini-pi.local (always on) ─────────────┐
          │ HubServer (pure Dart AOT exe, systemd, Restart=always)                │
          │  ├─ pairing/auth, devices & roles (owner, controller, display)        │
          │  ├─ modules: library, playlist, player, settings, display (modules.md) │
          │  ├─ HTTP: media routes with Range, resumable uploads, /health,        │
          │  │        update.json + APK (media-server.md)                         │
          │  ├─ worker: image variants, ffprobe, poster frames                    │
          │  ├─ inbox watcher (Samba share, CAP-9)                                │
          │  ├─ admin CLI: `tvsaver admin reset-pairings`                         │
          │  └─ drift SQLite + media dir                                          │
          │ Avahi: _tvsaver._tcp, port 8772                                       │
          └────────────▲───────────────────────────────▲──────────────────────────┘
                       │ WS JSON + HTTP                 │ WS JSON + HTTP (streaming)
                  Phone(s) ≤ 7                     Sony X90K TV app (1 display)
                  owner / controller               ├─ player: SurfaceView video (HDR, frame-rate match),
                                                   │          image decoder / native 4K image path
                                                   └─ LRU media cache
```

## Changes to the connection spec

| Connection spec | This app |
| --- | --- |
| TV hosts `HubServer` | The Pi hosts it. The TV is a WebSocket/HTTP client, like a phone. |
| TV is authoritative | The Pi is authoritative for library, playlists, pairings, settings. The TV is authoritative for what is on screen (current item, state, position). |
| First paired device is `owner` | The first paired **phone** is `owner`, later phones are `controller`. The TV has its own role, `display`, and is never owner. |
| QR/PIN shown on the TV pairing screen | The TV sends `devices.startPairing`; the Pi streams the rotating pair code / PIN to it as targeted `display.pairing` frames. The TV renders the QR. Same rules: single use, 120 s, lockout after 3 tries. |
| TV UI uses `localEvents` / `invokeLocal` (CAP-11) | The TV UI sends requests over its socket. Requests from the remote are owner-equivalent (physical presence). When the Pi is unreachable, the remote controls the cached playlist locally (see Offline and resync). |
| TV mDNS advertiser via `NsdManager` | Avahi service file on the Pi. Phones and the TV both use the scanner + last-address path. |
| `serve_tv_update` on the dev PC | The Pi hosts `update.json` + APK permanently (CAP-10). |
| Server lives in the TV Activity (non-goal) | Solved: the Pi is always on. |
| Hot live frames (CAP-6) | Not used. |
| 8 phones | 8 connections total: 1 display + up to 7 phones. |

Unchanged: framing, handshake, requests/`rid`/`op`, revisioned events + `sync`, heartbeat and clock offset, versioning, `replaced`, token storage and hashing.

## TV as a device

- The TV pairs with the Pi once and stores its token in secure storage like a phone does. Its device record has `kind: display`.
- **First display:** while no display is paired, the Pi accepts the first TV that connects with `hello {kind: display}` and gives it a token.
- **New or wiped TV:** once a display is paired, a new one needs approval from any paired phone, owner or controller (`devices.approveDisplay`). If no phone is paired at all, the Pi accepts it and it replaces the old display (physical presence is the only proof left).
- **v1: one active display.** A second display gets `err {code: conflict}`. Player state (`player.*`, `display.*`) is keyed by display id, so adding a second TV later (each with its own playlist) needs no protocol change.
- On every connect, the TV sends `display.capabilities` (decoders, HDR formats, render and panel size). The Pi stores it per display and uses it to accept or reject media.
- While no phone is paired, the TV shows the pairing screen automatically.

## Offline and resync (CAP-8)

- **Pi unreachable:** the TV loops the cached subset of the current playlist. The remote's next/prev/pause/seek/mute act locally.
- **Display not connected:** the Pi answers phone `player.*` with `err {code: unavailable}`. Phones show "TV not connected". No intents queue up.
- **Reconnect:** the TV sends `player.report {playlistId, index, itemId, state, positionMs, at}` before applying the snapshot. The Pi adopts it and emits `player.changed`. Playlist edits made in the meantime apply at the next item boundary, never mid-item. The picture never jumps.
- A Pi restart loses nothing: the TV's report restores the player state.

## Recovery

- **Owner phone lost:** on the TV, hold Back for 10 s → "Forget all phones" (`devices.forgetAll` from the remote). Phone pairings are deleted; the next phone to pair becomes owner.
- **TV wiped or replaced:** see "New or wiped TV" above.
- **Last resort:** `tvsaver admin reset-pairings` (over SSH on the Pi) deletes every device and closes all sockets. The next TV to connect becomes the first display, and the next phone to pair becomes owner.

## Code layout

```
packages/hub_core/   pure Dart: protocol, HubServer, modules, drift schema, clients
bin/pi_server.dart   Pi entry point → dart compile exe (linux-arm64), also the admin CLI
lib/main_phone.dart  Flutter phone app (com.codedbykay.tvsaver)
lib/main_tv.dart     Flutter TV app (com.codedbykay.tvsaver.tv, android-arm, 32-bit)
tool/                deploy to Pi, test media generators, tv/display_report.sh
```

Source for copying: `../drawing_poc` `lib/lan`, `lib/tv/server`, `lib/tv/update`, `test/support`. Strip Flutter imports while moving them into `hub_core`.
