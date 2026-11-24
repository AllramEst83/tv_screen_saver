# Modules and messages (CAP-5, CAP-6, CAP-7)

Built on the connection spec's framing (`<module>.<action>` requests with `rid`/`op`, `event {rev, module, kind, data}`, snapshot modules). First draft. Names may change while building, but the semantics hold.

| Module | Requests | Events / targeted frames | Owner only |
| --- | --- | --- | --- |
| `library` | `library.exists {sha256}`, `library.rename {id, name}`, `library.delete {id}` | `library.added`, `library.updated` (variants ready), `library.removed` | delete |
| `playlist` | `playlist.create/update {id?, name, items[], shuffle, imageSeconds, transition, kenBurns, muted}`, `playlist.delete {id}` | `playlist.changed`, `playlist.removed` | delete |
| `player` | `player.play {playlistId, index?}`, `player.next`, `player.prev`, `player.pause`, `player.resume`, `player.seek {positionMs}`, `player.setMuted {muted}` | `player.changed {playlistId, index, itemId, state, positionMs, startedAt, muted}` | — |
| `player` (display only) | `player.position {itemId, positionMs, durationMs?, at}` every 10 s and on change; `player.report {playlistId, index, itemId, state, positionMs, durationMs?, muted?, at}` on every (re)connect; `player.ended {itemId}` when the item played to its end | `position` updates the snapshot only, no `rev` bump. `report` is adopted and emits `player.changed`. `ended` makes the Pi start the next item (wraps to index 0), ignored unless `itemId` is the current item | — |
| `settings` | `settings.update {…}` (cache cap, storage cap, streaming ceiling, default image seconds, transition) | `settings.changed` | yes |
| `display` (display only) | `display.capabilities {decoders[], hdr[], render, panel}` on every connect | stored per display | — |
| `display` (Pi → TV, targeted) | — | `display.load {itemId, variant, startAt, muted}`, `display.control {action, positionMs?, muted?}`, `display.prefetch {itemIds[]}`, `display.pairing {qr, pin, expiresAt}` | — |
| `devices` | `hello {kind?: "phone"\|"display"}` (absent = phone; any other value is `err invalid`); rename, forget, `devices.forgetAll` (owner or display; also from the remote: hold Back 10 s; a controller gets `err forbidden`); `devices.approveDisplay {requestId}` (any paired phone; `not_found` once the request ended, `conflict` if the TV could not be admitted); `devices.startPairing` / `devices.cancelPairing` (display only) | from the connection spec; targeted: `devices.approvalRequested {requestId, name}` and `devices.approvalCancelled {requestId}` to phones (approved, timed out or the TV left), `display.pairing {qr, pin, expiresAt}` to the display on start, every rotation and after each pairing | forget, forget all |

Errors on this path: `unavailable` (phone pairs while no session is open, or the Pi has no LAN address for the QR), `timeout` (no phone approved the waiting TV in time, 120 s), `conflict` (a TV is already connected or waiting, or the 7-phone cap is reached), `invalid` (unknown `kind`).

- `display.load` starts an item (`startAt` is a position in milliseconds, `muted` the player's mute state). `display.control {action}` is `pause`, `resume` or `seek` (each with `positionMs`) or `mute` (with `muted`). `player.play`, `next`, `prev` and `ended` send `display.load`; `pause`, `resume`, `seek` and `setMuted` send `display.control`.
- `display` also has the event `display.changed {online}` (broadcast when the display connects or leaves) and the snapshot `{online}`; `player` has the snapshot `{playlistId, index, itemId, state, positionMs, startedAt, muted, at}` (state `idle|playing|paused`, `positionMs` is the position now). While playing, a phone's position is `piNow - startedAt`.
- Until story 4-4 the only playlist is `all`: the files of the Pi media directory sorted by name, except dot files and `*.bin` (the throughput test file). An unknown playlist or an empty one gives `err not_found`; `next`, `prev`, `pause`, `resume` and `seek` with nothing playing also give `not_found`. A `seek` past the end clamps to the duration the TV reported (`durationMs`).
- A `player.position` the TV sent before a Pi-side seek, play or next cannot undo it (the Pi ignores TV positions for 2.5 s after those).
- Defaults: `muted: false` (video sound plays), `kenBurns: false`, `transition: crossfade`. Volume stays on the TV remote.
- `player.setMuted` overrides the playlist flag until the next `player.play`.
- `startedAt` and `at` are absolute TV/Pi times (connection spec clock rules), so phones show progress without polling.
- `player.*` commands from phones go to the Pi, which emits `player.changed` and sends `display.load` to the TV. With no display connected the Pi returns `err {code: unavailable}`.
- `player.*` from the TV remote go the same way and are owner-equivalent. Remote FF/RW maps to `player.seek` (±30 s); phones get a scrub bar. When the Pi is offline, the TV applies them locally and reports the result on reconnect (`architecture.md`).
