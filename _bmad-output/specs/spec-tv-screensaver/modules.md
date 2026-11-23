# Modules and messages (CAP-5, CAP-6, CAP-7)

Built on the connection spec's framing (`<module>.<action>` requests with `rid`/`op`, `event {rev, module, kind, data}`, snapshot modules). First draft. Names may change while building, but the semantics hold.

| Module | Requests | Events / targeted frames | Owner only |
| --- | --- | --- | --- |
| `library` | `library.exists {sha256}`, `library.rename {id, name}`, `library.delete {id}` | `library.added`, `library.updated` (variants ready), `library.removed` | delete |
| `playlist` | `playlist.create/update {id?, name, items[], shuffle, imageSeconds, transition, kenBurns, muted}`, `playlist.delete {id}` | `playlist.changed`, `playlist.removed` | delete |
| `player` | `player.play {playlistId, index?}`, `player.next`, `player.prev`, `player.pause`, `player.resume`, `player.seek {positionMs}`, `player.setMuted {muted}` | `player.changed {playlistId, index, itemId, state, positionMs, startedAt, muted}` | — |
| `player` (display only) | `player.position {itemId, positionMs, at}` every 10 s and on change; `player.report {playlistId, index, itemId, state, positionMs, at}` on every (re)connect | `position` updates the snapshot only, no `rev` bump. `report` is adopted and emits `player.changed` | — |
| `settings` | `settings.update {…}` (cache cap, storage cap, streaming ceiling, default image seconds, transition) | `settings.changed` | yes |
| `display` (display only) | `display.capabilities {decoders[], hdr[], render, panel}` on every connect | stored per display | — |
| `display` (Pi → TV, targeted) | — | `display.load {itemId, variant, startAt}`, `display.prefetch {itemIds[]}`, `display.pairing {qr, pin, expiresAt}` | — |
| `devices` | from the connection spec: rename, forget, forget all (also from the remote: hold Back 10 s); `devices.approveDisplay` (any paired phone); `devices.startPairing` / `devices.cancelPairing` (display only) | from the connection spec | forget, forget all |

- Defaults: `muted: false` (video sound plays), `kenBurns: false`, `transition: crossfade`. Volume stays on the TV remote.
- `player.setMuted` overrides the playlist flag until the next `player.play`.
- `startedAt` and `at` are absolute TV/Pi times (connection spec clock rules), so phones show progress without polling.
- `player.*` commands from phones go to the Pi, which emits `player.changed` and sends `display.load` to the TV. With no display connected the Pi returns `err {code: unavailable}`.
- `player.*` from the TV remote go the same way and are owner-equivalent. Remote FF/RW maps to `player.seek` (±30 s); phones get a scrub bar. When the Pi is offline, the TV applies them locally and reports the result on reconnect (`architecture.md`).
