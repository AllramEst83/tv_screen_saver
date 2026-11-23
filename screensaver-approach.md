# TV screensaver app: approach and recommendations

> Builds on `phone-tv-connection-consolidated.md` (the phone ↔ TV spec). Target: Sony XR-55X90K (Google TV, Android 12, 32-bit ARM, ~4 GB app storage), Android phone, Raspberry Pi 5, TP-Link AX1500 router. Both apps in Flutter.
>
> Items marked **(verify)** are things I'm fairly sure of but you should check on your own hardware before building on them.

---

## 1. TL;DR

1. **Don't build a real Android "screensaver" (DreamService).** Build a normal full-screen TV app that holds a wakelock (`wakelock_plus`), as the spec already says. Then turn off Sony's **Idle TV standby**, which is a separate timer that a wakelock may not stop.
2. **Use the Raspberry Pi 5 as the media library and the always-on hub.** The Pi stores the files, makes thumbnails and previews, and runs the pairing/state server from the spec. The TV becomes a **display client** that streams from the Pi over HTTP and keeps a small offline cache. The phone pairs with the Pi.
3. **IP addresses:** set up **DHCP Address Reservation** on the TP-Link for the Pi and the TV. The phone doesn't need one. Plug the Pi and, if you can, the TV into the router with Ethernet.
4. **4K output:** on most Android TVs the app UI layer, Flutter included, is drawn at **1080p**. Only video on a hardware `SurfaceView` reaches the panel at full 4K. So play video through a **platform view (SurfaceView)**, not the default texture. For true 4K stills, the Pi can turn each image into a short 4K HEVC clip.
5. **Power on/off on a schedule** from the Pi with Sony's **BRAVIA IP Control (REST)** API, or with ADB over the network, so the TV isn't on 24/7.

---

## 2. Keeping the TV on and awake

### 2.1 Options

| Option | How | Verdict |
| --- | --- | --- |
| **A. Foreground app + wakelock** | Full-screen Activity, `WakelockPlus.enable()` (`FLAG_KEEP_SCREEN_ON`) while showing content | **Recommended.** Simple, Flutter-native, and matches the spec (server lives in the Activity, TV UI is the display). |
| B. Android `DreamService` (a real screensaver) | Native service in the manifest with `BIND_DREAM_SERVICE`. On Google TV it has to be chosen with `adb shell settings put secure screensaver_components <pkg>/<DreamClass>`, because Google TV's Ambient Mode hides third-party screensavers from the settings UI **(verify)** | Not worth it as the main path. Hosting Flutter inside a `DreamService` (a manual `FlutterEngine` + `FlutterView`) isn't officially supported. The dream can be killed whenever the user presses a key, and it fights with the spec's "server lives in the Activity" model. |
| C. Tiny native DreamService that just launches the app (A) | The dream calls `startActivity(...)` and then `finish()` | An optional extra later. It means "when the TV goes idle, the screensaver app takes over". Worth a short spike on the X90K **(verify)** that activity launch from a dream is allowed. |

### 2.2 Settings to change on the X90K

- **Idle TV standby → Off** (Settings → System → Power and energy → Idle TV standby; menu names vary by firmware). This turns the TV off after 1–4 h with no remote input, **even while an app is playing**. It's the most likely reason the TV would turn off.
- **Screensaver / Ambient Mode:** with the wakelock held it won't start, but you can still set "When to start" to the longest value as a backup.
- **Picture power saving / Eco → Off**, or the backlight may dim over time.
- **Remote start → On** (Settings → Network & Internet), needed to power the TV on over the network (§6).
- **Burn-in:** the X90K is a full-array LED LCD, not OLED, so burn-in isn't a concern. A slow Ken Burns pan/zoom still looks better and is cheap on the GPU.

### 2.3 In the TV app

- `WakelockPlus.enable()` while content plays, and disable it only when the app shows an idle/"off" screen on purpose.
- Use an immersive full-screen mode (`SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky)`).
- On start, restore the last playlist and position, so after any restart, power cycle or app switch you're back in seconds (spec: "make reopening cheap").
- Long-running stability: once a day (e.g. at the nightly power-off), dispose and recreate players and clear the image cache. Watch memory on the 32-bit device, where a decoded 4K RGBA frame is about 33 MB.

---

## 3. 4K images and video on Android TV with Flutter

### 3.1 The 1080p UI plane (important)

On most Android TVs, including MediaTek-based Sonys like the X90K **(verify)**, the **graphics/UI plane is 1920×1080**. The panel is 4K, but only the **video plane** (a hardware-composed `SurfaceView`) is shown at native 3840×2160. Flutter draws everything in the UI plane, so:

- **Video through a Flutter texture** (the default `video_player` mode) is composited into the UI plane, so it's downscaled to 1080p, and HDR is usually lost.
- **Video through a `SurfaceView` platform view** stays on the video plane at full 4K, and HDR (HDR10/HLG/Dolby Vision) can pass through.
- **Still images** drawn by Flutter come out at 1080p, however big the source is.

Measure it first. Log `Display.getMode().physicalWidth/Height` against the Flutter surface size (`MediaQuery.sizeOf(context) * devicePixelRatio`) through a small method channel. If the Flutter surface is 1920×1080, the above applies.

### 3.2 Video

- **Player:** `video_player` (ExoPlayer/Media3 on Android). Use the **platform-view (SurfaceView) mode**: recent `video_player` versions expose `VideoViewType.platformView` **(verify on the version you install)**. If that's missing or misbehaves on the TV, write a small native `PlayerView` (Media3) and embed it as a platform view.
- **Auth:** `VideoPlayerController.networkUrl(uri, httpHeaders: {'Authorization': 'Bearer …'})`. That keeps the spec rule "never put the token in a URL".
- **Seamless playlists:** keep two controllers, the current one and the next one prepared in advance, then crossfade or cut at the end. Looping a single long video: `setLooping(true)`.
- **Formats:** use **HEVC (H.265) Main10, 3840×2160, ≤ 60 fps, ~20–50 Mbps** in MP4/MKV. Check what the TV actually decodes with `MediaCodecList` on the device (HEVC, VP9 and possibly AV1 **(verify)**).
- **Transcode on the PC, not the Pi.** The Pi 5 has **no hardware video encoder**, so software 4K HEVC encoding on it is very slow. Prepare files with HandBrake/ffmpeg on the PC, or upload phone videos as they are when they're already HEVC/H.264. The Pi only **checks** files with `ffprobe` (codec, resolution, duration) and pulls a poster frame with `ffmpeg`, which is cheap.

### 3.3 High-resolution images

- **Simple path (1080p output):** the Pi generates a **3840 px and a 1920 px variant** of each image (libvips or ImageMagick; fast on a Pi 5). The TV downloads the variant that matches its UI plane and decodes with `cacheWidth` set to the real surface width, so it never decodes a 24 MP original on a 32-bit device.
- **True-4K path:** the Pi turns each image into a **short 4K HEVC clip** (e.g. 10–30 s of a still, or with a slow Ken Burns pan baked in), and the TV plays it on the 4K video plane. A still image compresses to a tiny file, and encoding at very low frame rates / `-tune stillimage` is light enough even in software on the Pi **(verify speed)**. Start with the simple path and add this as a per-item "4K mode" if the difference is visible on your TV.
- Transitions: preload the next image (`precacheImage`), crossfade with `AnimatedSwitcher`, and keep the pan/zoom on the GPU (`Transform`) per the spec's TV rendering rules.
- Strip EXIF GPS on the phone before upload (spec rule). Apply EXIF orientation on the Pi when making variants.

---

## 4. Raspberry Pi 5 as the media server: yes, and as the hub

### 4.1 Why the Pi is a good fit

- **Storage:** the TV has about 4 GB for apps, and 4K video takes ~2–20 GB per hour. Put a **USB 3 SSD or an NVMe HAT** on the Pi, not the SD card, for capacity and endurance.
- **Bandwidth:** a 50 Mbps 4K stream is easy. The **Pi 5 has gigabit Ethernet**. The **X90K's Ethernet port is 100 Mbps** **(verify)**, which still has twice the headroom, and its Wi-Fi 5 also works. Wired is the most reliable for 24/7 playback.
- **Always on:** the phone can manage the library and playlists while the TV is off or the TV app is closed. That removes the spec's main limitation ("server lives in the TV Activity").

### 4.2 Recommended topology: Pi = hub, TV = display client

```
             ┌──────────── Raspberry Pi 5 (always on, fixed IP) ─────────────┐
             │ HubServer (same protocol as the spec, pure Dart, AOT exe)     │
             │  ├─ pairing/auth, devices & roles (phones + TV display)       │
             │  ├─ modules: library, playlists, player, settings, schedule   │
             │  ├─ HTTP: /media upload (resumable), /media/<id>/<variant>    │
             │  │        with Range support, /health                         │
             │  ├─ worker: ffprobe, poster frames, image variants            │
             │  ├─ TV power control (BRAVIA REST / adb)                      │
             │  └─ SQLite (drift) + /srv/media on SSD; optional Samba inbox  │
             └──────────▲───────────────────────────▲────────────────────────┘
                        │ WS + HTTP                 │ WS + HTTP (streaming)
                    Phone(s)                   Sony TV app (display client)
                                               └─ local LRU cache (~1–1.5 GB)
```

How this maps onto the spec:

| Spec concept | In this app |
| --- | --- |
| "The TV is authoritative" | **The Pi is authoritative.** The TV holds the authoritative *playback position* and reports it (`player.position` targeted frames / periodic events). |
| Pairing needs physical presence (PIN/QR on the TV) | Still true. The Pi has no screen, so it sends the current pair code/PIN to the **paired TV display client**, which shows the QR/PIN. Pairing still needs someone in front of the TV. |
| TV UI drives the same handlers (CAP-11) | The TV remote sends requests to the Pi like a phone does, with role `owner` (physical presence). When offline, the TV keeps playing its cached playlist on its own. |
| TV pairing | The TV itself pairs with the Pi once. First boot: the Pi runs a one-off "accept first display" window, or the TV shows a code you approve from the phone. It then stores a token like a phone does. |
| mDNS (CAP-1/3) | The Pi announces `_tvsaver._tcp` with **Avahi** (one service file). With a DHCP reservation, the "last known address" step almost always succeeds. |
| Live control (CAP-6) | Mostly unneeded. Keep the hot-frame path only if you later add phone-driven pan/zoom of an image. |
| File transfer (CAP-7) | Goes to the Pi instead, with a much larger limit and **resumable** uploads (§4.4). |
| Wi-Fi updates (CAP-10) | Unchanged for the TV APK. The Pi can host `update.json` + APK permanently, so no need to run `serve_tv_update` on the PC. |

App parameters (new, unique per the spec): mDNS `_tvsaver._tcp`, port **8772**, QR scheme `tvsaver://`.

**Simpler alternative, if you want to start smaller:** keep the spec exactly as written (the TV is the hub) and run the Pi as a **plain authenticated file server** (Dart `shelf` or nginx with Range support). The TV stores a Pi token, and the phone uploads to the Pi through a short-lived upload ticket the TV gives it. It's less work at first, but the phone can't do anything while the TV app is closed, and you need two pieces of auth. I'd only pick this for a quick proof of concept.

### 4.3 Code structure for sharing the server

- The spec's `lib/tv/server` + `lib/lan` must not import Flutter, so they can run on the Pi. Move them into a **pure-Dart package** in the repo (e.g. `packages/hub_core`) used by:
  - `bin/pi_server.dart` → `dart compile exe` for linux-arm64 (on the Pi, or cross-compiled with `--target-os=linux --target-arch=arm64` on a recent Dart SDK), run as a **systemd service** with `Restart=always`.
  - `lib/main_phone.dart` and `lib/main_tv.dart` (Flutter) for the client side.
- drift on the Pi: use `NativeDatabase` with the system `libsqlite3` (`apt install libsqlite3-dev`).
- On the Pi, replace the Android `NsdManager` advertiser with an Avahi service file (or keep a Dart mDNS responder behind an interface).

### 4.4 HTTP routes on the Pi

| Route | Notes |
| --- | --- |
| `POST /media/uploads` → `{uploadId}` | Starts a resumable upload with name, size, sha256, mime |
| `PUT /media/uploads/<uploadId>` with `Content-Range` | Chunks of 8–32 MB. On reconnect, `HEAD` returns the received offset. Multi-GB videos must survive a phone screen lock or a Wi-Fi blip. |
| `GET /media/<id>/<variant>` | `thumb`, `1080`, `2160`, `poster`, `original`. **Must support `Range` / `206 Partial Content`**, or ExoPlayer can't seek and starts slowly. |
| `DELETE /media/<id>` | Owner only |
| `GET /health` | No auth, per the spec |

- Hashing a multi-GB file on the phone takes a while: hash in an isolate, streaming, and show progress. The duplicate check (`library.exists {sha256}`) still saves a lot here.
- **From the PC:** a **Samba "inbox" share** on the Pi that the server watches and imports from is the easiest way to load big video files. Same LAN, no app needed.
- Storage cap with an explicit "disk full" message, never silent deletion (spec rule).

### 4.5 TV-side cache

- An LRU cache in the app's files dir, capped at about 1–1.5 GB (leave room for the system and other apps), holding image variants and the *current* playlist's short clips.
- If the Pi is unreachable, keep playing what's cached and show a small "library offline" badge only on the remote's info overlay, never on the main picture.

### 4.6 Suggested modules / messages (first draft)

- `library`: `library.exists {sha256}`, `library.rename`, `library.delete` (owner); events `library.added`, `library.updated` (variants ready), `library.removed`.
- `playlist`: `playlist.create/update/delete {id, name, items[], shuffle, imageSeconds, transition}`.
- `player`: `player.play {playlistId, index?}`, `player.next`, `player.prev`, `player.pause`, `player.resume`. Event `player.changed {playlistId, index, itemId, startedAt}`, where `startedAt` is an absolute time per the spec, so phones can show progress without polling.
- `display` (Pi → TV, targeted): `display.load {itemId, variant, startAt}`, `display.prefetch {itemIds[]}`, `display.pairing {qr, pin, expiresAt}`.
- `schedule`: on/off times per weekday, plus `schedule.powerNow {on|off}`.

---

## 5. Static IPs on the TP-Link AX1500

**Short answer:** yes, the router changes IPs over time (DHCP leases), but you can pin them. Use **Address Reservation** in the router rather than a static IP set on each device: it's managed in one place and can't clash.

### 5.1 Steps

1. Open `http://tplinkwifi.net` (or `http://192.168.0.1`) → **Advanced → Network → DHCP Server → Address Reservation → Add** (wording varies slightly by firmware; the TP-Link **Tether** app has the same option **(verify)**).
2. For each device, enter its **MAC address** and the IP to pin, e.g.:
   - Raspberry Pi 5 (Ethernet MAC) → `192.168.0.10`
   - Sony TV (Ethernet *or* Wi-Fi MAC, whichever it uses) → `192.168.0.11`
3. Reboot the device or reconnect it to the network to pick up the reserved address.

### 5.2 Gotchas

- **MAC randomization:** Android/Google TV and Android phones may use a **randomized MAC per Wi-Fi network**. It's normally stable for a given network, so a reservation works, but it changes if you "forget" and rejoin the network. On the TV, set Wi-Fi privacy to **"Use device MAC"** if your firmware offers it, or simply use **Ethernet**, which uses the hardware MAC. You can find the MAC the router sees in its **Client list**.
- **Wired MAC ≠ Wi-Fi MAC.** Reserve the MAC of the interface the device actually uses.
- **The phone needs no reservation.** It always connects outward and finds the Pi by last address → mDNS → QR (spec CAP-3).
- **Same network:** keep the phone, TV and Pi on the **main** Wi-Fi/LAN, not the **Guest network**, because the AX1500's guest network isolates clients. The 2.4 GHz and 5 GHz bands are the same subnet, so that's fine.
- **Pi OS:** leave the Pi on DHCP (NetworkManager default on Bookworm) and let the reservation do the work. If you ever do set a static IP on the Pi, choose one **outside** the router's DHCP pool.
- **Fallbacks still matter:** keep mDNS discovery and the QR path from the spec. The reservation just makes the fast path almost always work.

---

## 6. Scheduling power (optional but worth it)

Running a 55" TV 24/7 uses roughly 2–3 kWh a day. Let the Pi turn it on and off:

- **Sony BRAVIA IP Control (REST), preferred:** on the TV, enable *Settings → Network & Internet → Home network → IP control*, with authentication "Normal and Pre-Shared Key", and set a PSK. Then the Pi calls:
  - `POST http://<tv>/sony/system` `{"method":"setPowerStatus","params":[{"status":true}],"id":1,"version":"1.0"}` with header `X-Auth-PSK: <key>`
  - `POST /sony/appControl` `getApplicationList`, then `setActiveApp {uri}` to launch the screensaver app after power-on.
  - Needs **Remote start = On** to wake from standby. **(verify)** that the menu paths and `setActiveApp` with a sideloaded app work on your firmware.
- **ADB over the network, fallback:** enable Developer options → Network debugging, accept the Pi's key once, then `adb shell input keyevent KEYCODE_WAKEUP` and `adb shell am start -n <pkg>/.MainActivity`. It's more fragile (debugging can switch itself off after updates), but it can do more.
- Keep the PSK/ADB key on the Pi only. Never send them to the phone.

---

## 7. Phased plan

1. **Spike on the TV (1–2 days):** a bare Flutter TV app that logs the display mode vs. the Flutter surface size, plays a 4K HEVC file from a USB stick/LAN with `video_player` in **texture** vs **platform-view** mode (compare sharpness on a fine-detail test clip), shows a 4K image, and holds a wakelock overnight with Idle TV standby off. This settles §3 on real hardware.
2. **Pi basics:** SSD, DHCP reservations, Avahi service, `shelf` file server with Range + bearer auth, systemd unit. The TV plays a hard-coded playlist from the Pi.
3. **Hub on the Pi:** extract `hub_core` from the reference implementation, add the TV display client, and pair the phone through the TV-shown QR.
4. **Library:** resumable uploads from the phone, Samba inbox, worker jobs (variants, posters, ffprobe validation), TV LRU cache.
5. **Player polish:** two-controller pre-buffering, crossfades, Ken Burns, info overlay on the remote.
6. **Schedule + power control** through BRAVIA REST, and Pi-hosted TV updates.
7. Optional: the "4K still as HEVC clip" mode, and the DreamService launcher (§2.1 C).

## 8. Tests to add on top of the spec's list

- Range requests: `206` with the right `Content-Range`, a seek in the middle of a file, and an unauthorized range → 401.
- Resumable upload: interrupt at 40 %, resume from `HEAD` offset, final sha256 matches. A wrong hash → rejected and the partial file deleted.
- TV offline mode: the Pi stops → the TV keeps looping cached items. The Pi returns → the TV resyncs (`sync`) without a playback glitch.
- Pairing relay: the pair code shown on the TV display client is single-use and rotates (same rules as the spec).
- Soak test: 24 h playback on the X90K with memory sampled hourly (no growth trend).
