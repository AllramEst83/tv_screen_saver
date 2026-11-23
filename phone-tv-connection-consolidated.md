# Phone ↔ TV connection: consolidated
> One-file copy of every file in `_bmad-output/specs/spec-phone-tv-connection/` (SPEC.md and its seven companions), in reading order. The originals stay the source; if they change, regenerate this file.

**Contents:** `SPEC.md`, `architecture.md`, `protocol.md`, `pairing-and-security.md`, `live-control.md`, `file-transfer.md`, `tv-platform.md`, `testing.md`

---

<!-- source: SPEC.md -->

## Phone ↔ TV connection

### Why

Reusable infrastructure for any app where an Android phone is the remote and editor and an Android TV app is the display. The pattern was proven in Family Hub (`tv_app_exploration`) and hardened in Drawing Aid on the Sony X90K. It covers finding the TV, pairing, staying connected with several phones, low-latency live gestures, file transfer and Wi-Fi updates. Each new TV app reuses this layer and only defines its own modules and messages.

### Capabilities

- **CAP-1**
  - **intent:** A phone finds the TV by scanning the LAN or by scanning a QR code on the TV.
  - **success:** mDNS scan lists the TV with its name within ~6 s on a multicast-capable LAN. The QR code alone connects when multicast is blocked (`pairing-and-security.md`).
- **CAP-2**
  - **intent:** A phone pairs with the TV once, by scanning a single-use QR code or typing a 4-digit PIN, and keeps a long-lived token.
  - **success:** A QR scan pairs with no further input. A reused QR code is refused. A PIN pairs after one correct entry. 3 wrong PINs give a 60 s lockout and rotate the credentials.
- **CAP-3**
  - **intent:** A paired phone reconnects on its own after a dropped connection or a TV IP change.
  - **success:** It tries the last address, then mDNS by hub id, then shows offline. Retries back off at 1, 2, 3, 5 and 8 s. A device answering with the wrong hub id is refused.
- **CAP-4**
  - **intent:** Up to 8 phones are connected at once, with owner and controller roles; the owner can forget one phone or all.
  - **success:** The 9th phone gets `conflict`. The same token connecting again replaces its old socket, which gets `replaced` and does not reconnect. A controller gets `forbidden` on owner actions. "Forget all" closes every socket and the tokens stop working.
- **CAP-5**
  - **intent:** Phones change TV state through requests and stay in sync through revisioned events and snapshots.
  - **success:** Each request gets `ok` or `err` by `rid` within 6 s. A retried `op` is not run twice. After a dropped event the phone sends `sync` and ends with the same state as the TV (`protocol.md`).
- **CAP-6**
  - **intent:** Live gestures on a phone reach the TV and other phones fast enough that the TV follows the finger.
  - **success:** Finger to TV takes under 50 ms typical and under 100 ms worst case on the X90K, measured with the profiling overlay. 1,000 hot frames relay in order with no DB writes. Stale `seq` frames are dropped (`live-control.md`).
- **CAP-7**
  - **intent:** Phones upload and download files to and from the TV without disturbing live control.
  - **success:** A request with no token gets 401 and a valid upload gets 201. A body over the size limit gets 413. A duplicate hash is detected before transfer. Live frames keep their latency during a 10 MB upload (`file-transfer.md`).
- **CAP-8**
  - **intent:** Phone and TV agree on time, so both show the same countdowns.
  - **success:** The offset is computed from the smallest-RTT pong. The phone and TV countdowns differ by under 100 ms.
- **CAP-9**
  - **intent:** Phones and TVs on different app versions keep working or say clearly what to update.
  - **success:** A newer phone gets `upgrade_tv` and points the user to the TV update. A newer TV serves an older phone. Unknown frame types are ignored.
- **CAP-10**
  - **intent:** The TV app updates itself over Wi-Fi from the developer PC.
  - **success:** With `serve_tv_update` running, the TV finds the new version, downloads it with progress, verifies sha256 and opens the Android installer (`tv-platform.md`).
- **CAP-11**
  - **intent:** The TV's own UI and remote drive the same state as phones, with no phone connected.
  - **success:** A TV UI action goes through the same handler as the phone request and emits the same event. It works with zero sockets open.

### Constraints

- The TV is authoritative: it holds the state, files and database. Phones send intents and render what the TV sends back.
- LAN only: no internet backend, accounts, relay or cloud.
- Each app has its own mDNS service type, port and QR scheme, so several apps coexist on one TV (`protocol.md` §App parameters).
- Frames from one phone are handled in order, so a slow handler delays every later frame from that phone. Hot handlers never await disk or DB work before broadcasting.
- WebSocket frames are at most 64 KB. Anything larger goes over HTTP.
- Tokens are 256-bit, stored as a SHA-256 hash on the TV and in secure storage on the phone, and never put in URLs or logs. Every HTTP route except `/health` requires the token.
- Targets: Android 8.0+ phones; Sony XR-55X90K (Google TV, Android 12, 32-bit ARM, weak CPU). One Flutter project per app, with `main_phone.dart` and `main_tv.dart` entry points and one app id.

### Non-goals

- TLS or encryption on the LAN, internet or remote access, NAT traversal.
- iOS phones, web clients, non-Android TVs.
- App modules and message catalogues. Each app defines its own on top of this layer (Drawing Aid: `../spec-drawing-aid/scene-protocol.md`).
- Family Hub's family members and parent/child roles. Devices with owner/controller roles replace them.
- A background service that keeps the server alive while the TV app is closed.

### Success signal

- A fresh app built on this layer pairs a phone by QR in one scan. A second phone pairs by PIN. Both follow a live pinch on the TV under 100 ms. One uploads a 10 MB file while the other keeps gesturing with no visible lag. After the TV's IP changes, both reconnect with no user action. The TV then updates itself from `serve_tv_update`.

### Assumptions

- The Drawing Aid code (`lib/lan`, `lib/tv/server`, `lib/tv/update`, `tool/serve_tv_update.dart`, `test/support`) is the reference implementation. A new app copies it and changes only the app parameters and modules (`architecture.md`).

---

<!-- source: architecture.md -->

## Architecture

```
┌──────────────────────────── Android TV app ──────────────────────────────┐
│  HubServer  (HTTP + WebSocket on one port, mDNS announcement)            │
│   ├─ Pairing & auth (QR code / PIN → token, SHA-256 hash in DB)          │
│   ├─ Handler registry (module → handlers; `hot` flag for live frames)    │
│   ├─ DevicesModule (rename, forget, roles)                               │
│   ├─ App modules  (defined per app, e.g. scene, library, settings)       │
│   ├─ HTTP routes  (/health, app file routes)                             │
│   └─ drift SQLite + app files dir                                        │
│  TV UI: in-process listener (localEvents / invokeLocal), not a socket    │
└──────────────────────────────▲─────────────────────▲─────────────────────┘
                               │ WS JSON + HTTP      │
                          Phone A                Phone B … (≤ 8)
```

- **TV UI is not a network client.** It listens to `HubServer.localEvents` and calls handlers through `HubServer.invokeLocal`, so the remote works with no socket (CAP-11). The TV remote counts as owner (physical presence).
- An app adds modules by registering `HubHandlerSpec`s: `requireOwner`, `hot`, handler. Modules contribute their part of the `snapshot`.

### Reference implementation

| Path (drawing_poc) | Role |
| --- | --- |
| `lib/lan/protocol.dart` | Constants, `encodeFrame`/`decodeFrame`, `PairQrData` |
| `lib/lan/hub_client.dart` | Phone client: handshake, `request()`, `sendFireAndForget()`, heartbeat, reconnect |
| `lib/lan/clock_offset.dart` | RTT-corrected clock offset (CAP-8) |
| `lib/lan/hub_scanner.dart`, `multicast_lock.dart` | Phone mDNS discovery, `MulticastLock` while scanning |
| `lib/lan/advertiser.dart` | TV mDNS announcement (Android `NsdManager`) |
| `lib/lan/token_store.dart` | Token in `flutter_secure_storage`, host hint in `SharedPreferences`, keyed by hub id |
| `lib/tv/server/hub_server.dart`, `hub_module.dart`, `devices_module.dart` | Multi-client server, pairing, registry, fan-out, roles |
| `lib/tv/update/updater.dart`, `update_manifest.dart`, `tool/serve_tv_update.dart` | Wi-Fi updates (CAP-10) |
| `android/.../MainActivity.kt` | `multicast` and `installer` method channels |
| `test/support/` | Test rig (`testing.md`) |

Originally ported from Family Hub (`tv_app_exploration`), with members removed and HTTP auth added.

---

<!-- source: protocol.md -->

## Protocol (CAP-5, CAP-8, CAP-9)

### App parameters

Every app picks unique values, so apps coexist on one TV.

| App | mDNS service | Default port | QR scheme |
| --- | --- | --- | --- |
| Family Hub | `_familyhub._tcp` | 8770 | `familyhub://` |
| Drawing Aid | `_drawaid._tcp` | 8771 | `drawaid://` |
| IPTV Explorer | `_iptvexplorer._tcp` | 8765 | — |

Common constants: `kWsPath = '/ws'`, `kMaxFrameBytes = 64 * 1024`, QR `<scheme>pair?v=1&h=<ip>&p=<port>&id=<hubId>&c=<pairCode>`.
If the port is taken, the server binds a random port. **The advertised port (mDNS / QR) is the truth.**

### Framing

- One UTF-8 JSON object per WebSocket **text** frame, each with `"t": "<type>"`.
- Frames over 64 KB, invalid JSON, or a missing string `t` are ignored. **Unknown types are ignored.**
- The same HTTP server serves `/ws`, `GET /health` (`{ok, id, v, clients}`, no auth) and the app's file routes.
- Each connection has an **ordered queue**. Different phones run independently.

### Handshake

```
phone → hello {v, client, token?, pairCode?}
  token valid    → ready
  pairCode valid → paired {token}            (QR path)
  neither        → pair_required → phone: pair {pin} → paired {token} | pair_failed {retryInMs?}
tv → ready    {v, id, name, now, device:{id, name, role}}
tv → snapshot {rev, now, modules:{<module>:{…}, …}}
```

- The phone checks `ready.id` against the expected hub id and disconnects on mismatch.
- Before `ready`, only `hello`, `pair` and `ping` are accepted. Anything else closes the socket.

### Requests

```
phone → {t:"<module>.<action>", rid:17, op:"7f3c…", …payload}
tv    → {t:"ok", rid:17, result:{…}}
tv    → {t:"err", rid:17, code:"invalid"|"unauthorized"|"forbidden"|"not_found"|"conflict"|"rate_limited"|"upgrade_tv", msg?}
```

- `rid` is a per-connection counter. The default timeout is **6 s**.
- `op` is an optional client id for idempotency. The TV caches the last **500** results by `op` and replays them. Use it for anything that must not happen twice.
- A handler exception becomes `err {code: invalid}` and never crashes the server.

### State updates

| Kind | Frame | `rev` | Receivers | Use |
| --- | --- | --- | --- | --- |
| Snapshot | `snapshot {rev, now, modules}` | current | one phone | after `ready`, on `sync` |
| Event | `event {rev, module, kind, data}` | +1 | every ready phone + TV UI | discrete changes |
| Targeted | `{t, …}` | none | one device | progress, per-device errors |
| Hot | `{t, …}` | none | every ready phone except the sender | live gestures (`live-control.md`) |

**Gap:** `rev ≠ lastRev + 1` → phone sends `sync {sinceRev}` and gets a full snapshot. Module state must stay small enough that a full resync is cheap.

### Heartbeat and time

- Phone sends `ping {ts}` every **5 s**; TV answers `pong {ts, now}`.
- The TV closes a ready socket after **20 s** silent, and a still-pairing socket after **120 s**.
- `now` (TV epoch ms) comes in `ready`, `snapshot` and `pong`. Phone: `rtt = phoneNow − ts`, `offset = tvNow + rtt/2 − phoneNow`, and it keeps the smallest-RTT sample of the last few pongs.
- Timers travel as **absolute TV times** (`endsAt`), never "seconds left".

### Versioning

- `hello.v` is the phone's protocol version. A phone newer than the TV gets `err {code: upgrade_tv}` and suggests the Wi-Fi update.
- A newer TV accepts older phones, which hide features they don't know.
- New message types are backwards compatible. Changing the meaning of an existing field needs a version bump.

---

<!-- source: pairing-and-security.md -->

## Pairing and security (CAP-1 – CAP-4)

### Two ways in

| | mDNS scan + PIN | QR code on the TV |
| --- | --- | --- |
| Finds the TV | TV announces the service with TXT `v`, `name`, `id` | QR holds IP, port, hub id |
| Pairs | User types the 4-digit PIN shown on the TV | QR holds a one-time code: **scan = paired** |
| Breaks when | Router blocks multicast (guest Wi-Fi, AP isolation, some mesh) | No camera; TV changed IP since the scan |

Keep both: QR for the first pairing, mDNS for finding the TV after an IP change. The phone holds `MulticastLock` only while scanning.

### Credentials

| Item | Value |
| --- | --- |
| PIN | 4 digits on the TV pairing screen |
| QR pair code | 128 random bits, base64url, **single use** |
| Lifetime | 120 s. Rotated after use, on expiry and whenever the pairing screen opens |
| Lockout | 3 wrong attempts → 60 s (`pair_failed {retryInMs}`), credentials rotate |
| Comparison | Constant-time |
| Session token | 256 random bits (64 hex), sent once in `paired {token}` |
| TV storage | SHA-256 hash only (`pairings` table) |
| Phone storage | Token in secure storage, last host/port/name in `SharedPreferences`, keyed by **hub id**, never by IP |

The pairing QR shows only on demand, never permanently.

### Devices and roles

- After `paired`, the TV creates a device record (`client` name from `hello`) and sends `ready`.
- The first paired device is `owner`; later ones are `controller`. Owner-only actions are app-defined (e.g. delete files, forget devices, TV-wide settings). The TV remote counts as owner.
- `device.rename` (self), `device.forget {deviceId}` (owner), "Forget all phones" on the TV: deletes the pairings and closes the sockets.
- Up to **8** ready connections; the 9th gets `err {code: conflict}` and is closed.
- The same token connecting again **replaces** its old socket. The old one gets `replaced` and does not reconnect.

### Reconnecting

On app start and whenever the socket drops:
1. Last known address (2.5 s timeout), accepted only if `ready.id` matches.
2. mDNS scan (~6 s) for that hub id.
3. Offline, with "Scan the QR code again".

Back-off is 1, 2, 3, 5, 8 s, then it stays at 8 s. Each reconnect gets a fresh snapshot, so nothing is replayed. When the TV answers but the app is closed, the app shows its own "open it on the TV" message. A DHCP reservation for the TV makes step 1 nearly always succeed.

### Security summary

- Only paired devices can do anything, and pairing needs physical presence (PIN or QR on the TV).
- Tokens are never sent in URLs or written to logs. HTTP uses `Authorization: Bearer <token>`.
- `/health` exposes only id, version and client count.
- User files never leave the LAN. Apps strip sensitive metadata (e.g. EXIF GPS) on the phone before upload.

---

<!-- source: live-control.md -->

## Live control (CAP-6)

### Hot frames carry absolute state

```
phone → <target>.live {seq, …full state}        hot, no rid, at most one per display frame
phone → <target>.set  {rid, op, …full state}    on gesture end, revisioned, persisted
tv    → (other phones) <target>.live {by, seq, …}
tv    → (all) event {kind:"<target>.changed", data:{…, by}}
```

- **Full state every time**, so a lost or reordered frame can't cause drift.
- **The phone coalesces:** at most one live frame per display frame (~16 ms), always the latest state, never a backlog.
- `seq` increases per phone. The TV drops a live frame whose `seq` is not higher than the last from that device.
- Only the `.set` at gesture end bumps `rev` and is persisted (debounced).
- Hot handlers use the connection's cached identity (`HubHandlerSpec(hot: true)`), do no DB access and never `await` before broadcasting.

### Two phones at once

Last writer wins, plus a **gesture claim**: while a device has sent live frames for a target in the last **300 ms**, live frames for that target from other devices are dropped. The claim lapses on its own, with no lock messages.

### Phone feedback is local

The phone applies the gesture to its own preview first, so it stays under the finger. Live frames from other phones are applied as they arrive. Phone and TV render with one shared package, so they match.

### TV rendering rules

1. A live frame repaints only the layer that changed. A dedicated `ValueNotifier` drives it, and the rest of the UI updates on events only.
2. Expensive work (decoding, layout of large content) never runs per live frame.
3. Decodes run one at a time and always end on the newest request. Parallel decodes finish out of order.
4. Vector overlays are `CustomPainter`s in a `RepaintBoundary`.
5. Per-pixel work runs on the GPU (`ColorFilter`, `FragmentShader`), never on the CPU UI thread.

### Latency budget

| Step | Target |
| --- | --- |
| Finger → phone preview | next frame (≤ 16 ms) |
| Phone → TV over Wi-Fi | 2–20 ms typical (watch for Wi-Fi power-save spikes) |
| TV frame received → drawn | ≤ 16 ms |
| **Finger → TV** | **< 50 ms typical, < 100 ms worst** |

Verify on the real TV with a profiling overlay showing frame time and the time between received live frames.

### Lessons from Family Hub

| Symptom | Cause | Rule |
| --- | --- | --- |
| Updates trickled onto the TV | Each frame awaited SQLite before broadcast, in the ordered queue | Broadcast first, persist later |
| Lag on every frame | Per-frame identity lookup in the DB | Cached identity for hot handlers |
| TV lagged behind the finger | Every live frame rebuilt the whole widget tree on a 32-bit CPU | Only the changed layer repaints |
| Content flickered | Parallel decodes finishing out of order | One decode at a time, newest wins |
| Drag started late | Flutter drag detection waits ~18 px and competes with pinch | Raw pointer events (`Listener`); count pointers |
| Artificial delay between inputs | A cooldown nobody asked for | No rate limit on the user's own input, only a high flood cap |

---

<!-- source: file-transfer.md -->

## File transfer (CAP-7)

### Why HTTP, not the WebSocket

- Frames over 64 KB are dropped by design. Phone files are usually megabytes.
- An upload inside the phone's ordered queue would block live frames for seconds.
- HTTP gives streaming, `Content-Length` and simple retries, and the TV can write straight to disk.

### Pattern

| Step | Rule |
| --- | --- |
| Duplicate check | The phone hashes the file (SHA-256) and asks `<module>.exists {sha256}` before uploading |
| Upload | `POST /<files>` with a raw body, `Content-Type`, `X-<File>-Name` and `X-<File>-Sha256`. Response `201 {id, …}` |
| Size limit | Per app (Drawing Aid: 20 MB). Larger bodies get `413` |
| Download | `GET /<files>/<id>/<variant>`, e.g. thumb / preview / full |
| Delete | `DELETE /<files>/<id>` (owner) or the equivalent request |
| Announce | After a successful upload the TV broadcasts `event {kind:"<module>.added", data:{id, …}}` |
| Derived files | Generated in a background isolate, so the TV UI thread never stalls |

### Authentication

- Every route except `/health` requires `Authorization: Bearer <token>`. The TV hashes the token and looks it up in `pairings`, with an in-memory hash → device cache instead of a DB hit per request.
- `401` without a valid token, `403` for owner-only actions.
- Never put the token in a URL. The phone's image and file loaders add the header.

### Storage on the TV

- Files go in the app's private files directory, with a DB row per file (`id, name, sha256, bytes, created_at, last_used_at` plus app fields).
- The X90K has about 4 GB for apps. Each app caps its storage. When the cap is reached, the owner gets an explicit "full" message with a cleanup action. Nothing is deleted silently.

---

<!-- source: tv-platform.md -->

## TV platform (Sony X90K and Android TV)

- **Build:** `flutter build apk --release --target-platform android-arm -t lib/main_tv.dart`. The X90K is 32-bit only.
- **Server lifetime:** the server lives inside the TV app's Activity, with no foreground service. If the user switches apps, phones go offline until it is reopened. Apps make reopening cheap (e.g. restore last state).
- **Keep screen on** (`wakelock_plus`) while content shows, so Google TV's screensaver doesn't start mid-session.
- **Overscan:** some picture modes crop the edges. Apps that draw near the edges offer a calibration screen (four corner markers, D-pad) and store the visible area.
- **D-pad:** every focusable element uses `TvFocusable` (focus ring from Family Hub). The basics of each app must work with the remote alone.
- **App id:** each app has its own id so it installs next to the others. Changing an app's id makes a separate install: the self-updater can't cross the change, and data starts fresh.
- **Release keystore from day one,** backed up. Without it, the installed TV app can't be updated.

### Wi-Fi updates (CAP-10)

- On the dev PC, `tool/serve_tv_update.dart` serves `update.json` (version, versionCode, url, sha256) and the APK.
- On the TV, `TvUpdater` / `UpdateManifest` check the saved source, download with progress, verify sha256 and open the Android installer through the `installer` method channel.
- Bump `versionCode` in `pubspec.yaml` on every release. A phone that gets `upgrade_tv` points the user to the TV's update action.

---

<!-- source: testing.md -->

## Testing

**Rig** (`test/support/`): a real `HubServer` on a random port, an in-memory drift DB, a fake clock, and scripted phone clients that speak the real protocol.

### Must-have tests

1. Pairing: QR code single use, PIN lockout after 3 tries, token reconnect, wrong hub id refused, `replaced`, 9th phone `conflict`.
2. Hot path: 1,000 live frames from one phone relay in order to a second phone with **no DB writes**. Only `.set` persists.
3. Stale frames: a live frame with an older `seq` is dropped.
4. Gesture claim: phone B's live frames are ignored within 300 ms of phone A's.
5. HTTP: no token → 401; valid upload → 201 plus the `added` event; duplicate hash detected; over the limit → 413; owner-only → 403 for a controller.
6. Resync: a dropped event triggers `sync`, and the phone ends with the same state as the TV.
7. Idempotency: a repeated `op` returns the cached result without running the handler again.
8. Clock: the offset with simulated asymmetric delay stays within the budget.
9. On device: the profiling overlay on the TV shows frame time and time between live frames while pinching.
