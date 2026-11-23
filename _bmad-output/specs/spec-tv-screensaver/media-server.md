# Media server and cache (CAP-4, CAP-8, CAP-9, CAP-10)

## HTTP routes (Pi, port 8772, same server as `/ws`)

| Route | Rule |
| --- | --- |
| `GET /health` | No auth. `{ok, id, v, clients}` |
| `POST /media/uploads` | Starts an upload: `{name, bytes, sha256, mime}` → `{uploadId}`. `409` if the sha256 already exists. |
| `PUT /media/uploads/<uploadId>` | Chunk with `Content-Range`, 8–32 MB each. |
| `HEAD /media/uploads/<uploadId>` | Returns the bytes received so far, to resume. |
| — on the last chunk | The Pi verifies the sha256. On a mismatch it deletes the partial file and returns `422`. On a match it returns `201 {id, …}` and broadcasts `library.added`. |
| `GET /media/<id>/<variant>` | Images: `thumb`, `1920`, `full`. Videos: `thumb`, `poster`, `full` (the file as uploaded). **Must** answer `Range` with `206` + `Content-Range`. |
| `DELETE /media/<id>` | Owner only (`403` otherwise). |
| `GET /update.json`, `GET /tv.apk` | TV self-update (CAP-10). |

- Every route except `/health` requires `Authorization: Bearer <token>`. `401` without one. There's an in-memory hash → device cache.
- Size limits: images 80 MB (after phone prep; fits a 4096 px RGBA PNG), videos 50 GB per file. `413` above.
- Unfinished uploads expire after 24 h.

## Storage (Pi)

- A media dir plus a drift row per item: `id, kind (image|video), name, sha256, bytes, width, height, duration_ms, codec, hdr, fps, bitrate, created_at`.
- Stored on the Pi's 128 GB SD card. The storage cap is a setting, 90 GB by default. When it's reached, the owner gets an explicit "full" message with a cleanup action. Nothing is deleted silently.

## Inbox (CAP-9, v1)

- A Samba share `inbox` on the Pi: the main route for large 4K/HDR masters from the PC. A watcher imports a file once its size has been stable for 10 s: hash, duplicate check, `ffprobe` against the display's capabilities, image fidelity rules (`media-fidelity.md`), variants, move into the media dir, `library.added`. Rejected files go to `inbox/rejected/` with a `.txt` reason.

## Streaming ceiling

- Phase 2 measures sustained Pi → TV Wi-Fi throughput: the TV app downloads a 1 GB test file from the Pi over HTTP (Kay runs it; the result goes in the spec memlog). The **streaming ceiling** is 60 % of that figure, stored as a setting.
- A video at or below the ceiling streams. A video above it is accepted (quality first), the phone shows a "plays after caching" note, and the TV plays it only once it is fully cached; until then the player skips it.

## TV cache (CAP-8)

- An LRU in the app's files dir, capped at **2.5 GB** (setting), which leaves ~1.5 GB of the TV's app storage for the app and APK updates.
- It prefetches the next items of the current playlist (`display.prefetch`). Videos larger than 25 % of the cap are streamed only and never cached; if such a video is also above the streaming ceiling, the Pi rejects it at upload with a message to lower its bitrate or size on the PC.
- When the Pi is unreachable, the TV loops the cached subset of the current playlist and shows an "offline" badge only on the remote's info overlay.
