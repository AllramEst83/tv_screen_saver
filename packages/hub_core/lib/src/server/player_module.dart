import 'dart:async';

import '../db/hub_database.dart';
import '../protocol.dart';
import 'display_module.dart';
import 'hub_module.dart';
import 'playlist_source.dart';

/// What the player is doing, as phones and the TV see it.
abstract final class PlayerState {
  static const idle = 'idle';
  static const playing = 'playing';
  static const paused = 'paused';
}

class _Player {
  String? playlistId;
  int index = 0;
  String? itemId;
  String state = PlayerState.idle;

  /// Position at the last change. While playing, the live position is
  /// `now - startedAt`.
  int positionMs = 0;
  int? startedAt;
  bool muted = false;
  int? durationMs;

  /// Position reports from the TV are ignored until then, so a stale one that
  /// was already on the wire cannot undo a seek.
  int ignorePositionUntil = 0;

  /// The display is connected right now.
  bool online = true;

  /// A phone or remote command changed the state since the display last
  /// connected: its `player.report` is then out of date.
  bool commandSinceConnect = false;
}

/// The `player` module: one player per display id.
///
/// Requests (phones and the TV remote, owner-equivalent; `unavailable` while
/// no display is connected):
/// `player.play {playlistId, index?}`, `player.next`, `player.prev`,
/// `player.pause`, `player.resume`, `player.seek {positionMs}`,
/// `player.setMuted {muted}`.
///
/// Display only:
/// - `player.position {itemId, positionMs, durationMs?, at?}`: updates the
///   state without a `rev` bump
/// - `player.report {playlistId, index, itemId, state, positionMs, durationMs?,
///   muted?, at?}`: on every (re)connect; adopted, emits `player.changed`
/// - `player.ended {itemId}`: the item finished; the Pi moves on (wraps at the
///   end of the playlist)
///
/// Event `player.changed {playlistId, index, itemId, state, positionMs,
/// startedAt, muted}`. Every command also sends the display a targeted
/// `display.load` (item changes) or `display.control` (everything else).
///
/// While the display is away the player is paused at its last position. When
/// it comes back its report is adopted only if no command arrived in between;
/// otherwise the Pi answers `adopted: false` and tells the TV what to show.
class PlayerModule implements HubModule {
  PlayerModule({
    required this.db,
    required this.display,
    required this.playlists,
    this.unplayableReason,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final HubDatabase db;
  final DisplayModule display;
  final PlaylistSource playlists;

  /// Why an item cannot be played (null when it can); `player.play` refuses
  /// such an item.
  final Future<String?> Function(String itemId)? unplayableReason;
  final DateTime Function() _now;

  /// How long a Pi-side position change shields against older TV reports.
  static const positionShield = Duration(milliseconds: 2500);

  final _events = StreamController<HubOutboundEvent>.broadcast();
  final Map<String, _Player> _players = {};
  Future<void> _serial = Future.value();
  bool _disposed = false;

  @override
  String get id => 'player';

  @override
  Stream<HubOutboundEvent> get events => _events.stream;

  int get _nowMs => _now().millisecondsSinceEpoch;

  @override
  Map<String, HubHandlerSpec> get handlers => {
    'player.play': HubHandlerSpec(handler: _play),
    'player.next': HubHandlerSpec(handler: (c) => _step(c, 1)),
    'player.prev': HubHandlerSpec(handler: (c) => _step(c, -1)),
    'player.pause': HubHandlerSpec(handler: _pause),
    'player.resume': HubHandlerSpec(handler: _resume),
    'player.seek': HubHandlerSpec(handler: _seek),
    'player.setMuted': HubHandlerSpec(handler: _setMuted),
    'player.position': HubHandlerSpec(handler: _position),
    'player.report': HubHandlerSpec(handler: _report),
    'player.ended': HubHandlerSpec(handler: _ended),
  };

  // ---- helpers ----

  Future<T> _serialized<T>(Future<T> Function() body) {
    final run = _serial.then((_) => body());
    _serial = run.then<void>((_) {}, onError: (Object _) {});
    return run;
  }

  /// Runs a phone or remote command against the connected display's player.
  Future<Object?> _command(
    Future<Object?> Function(String displayId, _Player p) body,
  ) => _serialized(() async {
    final displayId = display.onlineDisplayId;
    if (displayId == null) {
      throw const HubError(HubErrorCode.unavailable, 'TV not connected');
    }
    final p = _players.putIfAbsent(displayId, _Player.new);
    p.commandSinceConnect = true;
    return body(displayId, p);
  });

  void _requireDisplay(HubCall call) {
    if (!call.device.isDisplay) {
      throw const HubError(HubErrorCode.forbidden, 'Only the TV can do this');
    }
  }

  _Player _playerOf(HubCall call) =>
      _players.putIfAbsent(call.device.id, _Player.new);

  int _positionNow(_Player p) {
    if (p.state != PlayerState.playing || p.startedAt == null) {
      return p.positionMs;
    }
    var pos = _nowMs - p.startedAt!;
    if (pos < 0) pos = 0;
    final dur = p.durationMs;
    if (dur != null && pos > dur) pos = dur;
    return pos;
  }

  Map<String, Object?> _json(_Player p) => {
    'playlistId': p.playlistId,
    'index': p.index,
    'itemId': p.itemId,
    'state': p.state,
    'positionMs': _positionNow(p),
    'startedAt': p.state == PlayerState.playing ? p.startedAt : null,
    'muted': p.muted,
  };

  void _emitChanged(_Player p) {
    if (_disposed || _events.isClosed) return;
    _events.add(
      HubOutboundEvent.broadcast(
        module: id,
        kind: 'player.changed',
        data: _json(p),
      ),
    );
  }

  String _requireString(Object? v, String field) {
    if (v is! String || v.isEmpty) {
      throw HubError(HubErrorCode.invalid, '$field is missing');
    }
    return v;
  }

  /// A JSON number that is a whole number, else null.
  int? _wholeNumber(Object? v) {
    if (v is int) return v;
    if (v is double && v.isFinite && v == v.truncateToDouble()) {
      return v.toInt();
    }
    return null;
  }

  Future<List<String>> _items(String playlistId) async {
    final ids = await playlists.itemIds(playlistId);
    if (ids == null) {
      throw const HubError(HubErrorCode.notFound, 'Unknown playlist');
    }
    if (ids.isEmpty) {
      throw const HubError(HubErrorCode.notFound, 'The playlist is empty');
    }
    return ids;
  }

  void _requireItem(_Player p) {
    if (p.itemId == null) {
      throw const HubError(HubErrorCode.notFound, 'Nothing is playing');
    }
  }

  /// Starts item [index] of [ids] at the start and tells the display.
  void _startItem(
    String displayId,
    _Player p,
    String playlistId,
    List<String> ids,
    int index,
  ) {
    p
      ..playlistId = playlistId
      ..index = index
      ..itemId = ids[index]
      ..state = PlayerState.playing
      ..positionMs = 0
      ..startedAt = _nowMs
      ..durationMs = null
      ..ignorePositionUntil = _nowMs + positionShield.inMilliseconds;
    _emitChanged(p);
    display.sendLoad(displayId, itemId: ids[index], startAt: 0, muted: p.muted);
  }

  /// Goes idle: nothing is playable. The TV is told to clear the picture.
  void _goIdle(String displayId, _Player p) {
    p
      ..itemId = null
      ..state = PlayerState.idle
      ..positionMs = 0
      ..startedAt = null;
    _emitChanged(p);
    display.sendControl(displayId, action: 'stop');
  }

  /// Starts the first playable item at or after [index] (moving by [delta],
  /// wrapping). Items the library says cannot be played are skipped; when
  /// none is playable the player goes idle. True when an item started.
  Future<bool> _startFrom(
    String displayId,
    _Player p,
    String playlistId,
    List<String> ids,
    int index,
    int delta,
  ) async {
    final n = ids.length;
    for (var k = 0; k < n; k++) {
      final i = (index + delta * k) % n;
      if (await unplayableReason?.call(ids[i]) == null) {
        _startItem(displayId, p, playlistId, ids, i);
        return true;
      }
    }
    _goIdle(displayId, p);
    return false;
  }

  // ---- phone and remote commands ----

  Future<Object?> _play(HubCall call) => _command((displayId, p) async {
    final playlistId = _requireString(call.args['playlistId'], 'playlistId');
    final rawIndex = call.args['index'];
    final index = rawIndex == null ? 0 : _wholeNumber(rawIndex);
    if (index == null) {
      throw const HubError(HubErrorCode.invalid, 'index must be a number');
    }
    final ids = await _items(playlistId);
    if (index < 0 || index >= ids.length) {
      throw const HubError(HubErrorCode.invalid, 'index is out of range');
    }
    final blocked = await unplayableReason?.call(ids[index]);
    if (blocked != null) {
      throw HubError(HubErrorCode.invalid, blocked);
    }
    p.muted = false; // `setMuted` lasts until the next `play`.
    _startItem(displayId, p, playlistId, ids, index);
    return null;
  });

  Future<Object?> _step(HubCall call, int delta) =>
      _command((displayId, p) async {
        _requireItem(p);
        final playlistId = p.playlistId!;
        final ids = await _items(playlistId);
        await _startFrom(
          displayId,
          p,
          playlistId,
          ids,
          _stepIndex(p, ids, delta),
          delta,
        );
        return null;
      });

  /// The index after (or before) the current item, wrapping at both ends. If
  /// the current item left the playlist its old index now holds the item that
  /// followed it.
  int _stepIndex(_Player p, List<String> ids, int delta) {
    final at = ids.indexOf(p.itemId!);
    final n = ids.length;
    if (at >= 0) return (at + delta) % n;
    return delta > 0 ? p.index % n : (p.index - 1) % n;
  }

  Future<Object?> _pause(HubCall call) => _command((displayId, p) async {
    _requireItem(p);
    final pos = _positionNow(p);
    p
      ..state = PlayerState.paused
      ..positionMs = pos
      ..startedAt = null;
    _emitChanged(p);
    display.sendControl(displayId, action: 'pause', positionMs: pos);
    return null;
  });

  Future<Object?> _resume(HubCall call) => _command((displayId, p) async {
    _requireItem(p);
    final pos = _positionNow(p);
    p
      ..state = PlayerState.playing
      ..positionMs = pos
      ..startedAt = _nowMs - pos;
    _emitChanged(p);
    display.sendControl(displayId, action: 'resume', positionMs: pos);
    return null;
  });

  Future<Object?> _seek(HubCall call) => _command((displayId, p) async {
    _requireItem(p);
    final raw = _wholeNumber(call.args['positionMs']);
    if (raw == null) {
      throw const HubError(HubErrorCode.invalid, 'positionMs must be a number');
    }
    var pos = raw < 0 ? 0 : raw;
    final dur = p.durationMs;
    if (dur != null && pos > dur) pos = dur;
    p
      ..positionMs = pos
      ..startedAt = p.state == PlayerState.playing ? _nowMs - pos : null
      ..ignorePositionUntil = _nowMs + positionShield.inMilliseconds;
    _emitChanged(p);
    display.sendControl(displayId, action: 'seek', positionMs: pos);
    return null;
  });

  Future<Object?> _setMuted(HubCall call) => _command((displayId, p) async {
    final muted = call.args['muted'];
    if (muted is! bool) {
      throw const HubError(HubErrorCode.invalid, 'muted must be true or false');
    }
    p.muted = muted;
    _emitChanged(p);
    display.sendControl(displayId, action: 'mute', muted: muted);
    return null;
  });

  // ---- display reports ----

  Future<Object?> _position(HubCall call) => _serialized(() async {
    _requireDisplay(call);
    final itemId = call.args['itemId'];
    final pos = _wholeNumber(call.args['positionMs']);
    if (itemId is! String || pos == null || pos < 0) {
      throw const HubError(
        HubErrorCode.invalid,
        'itemId or positionMs invalid',
      );
    }
    final p = _playerOf(call);
    if (p.itemId != itemId) return null; // Stale: another item is current.
    final dur = _wholeNumber(call.args['durationMs']);
    if (dur != null && dur > 0) p.durationMs = dur;
    if (_nowMs < p.ignorePositionUntil) return null;
    p.positionMs = pos;
    if (p.state == PlayerState.playing) p.startedAt = _nowMs - pos;
    return null; // The snapshot changes; no event, no `rev`.
  });

  Future<Object?> _report(HubCall call) => _serialized(() async {
    _requireDisplay(call);
    final state = call.args['state'];
    if (state != PlayerState.idle &&
        state != PlayerState.playing &&
        state != PlayerState.paused) {
      throw const HubError(HubErrorCode.invalid, 'state is invalid');
    }
    final p = _playerOf(call);
    if (p.commandSinceConnect) {
      await _reconcile(call.device.id, p);
      return {'adopted': false};
    }
    final itemId = call.args['itemId'];
    if (itemId == null || state == PlayerState.idle) {
      // The TV shows nothing: the Pi forgets what it thought was playing.
      p
        ..playlistId = null
        ..index = 0
        ..itemId = null
        ..state = PlayerState.idle
        ..positionMs = 0
        ..startedAt = null
        ..durationMs = null;
      if (call.args['muted'] is bool) p.muted = call.args['muted'] as bool;
      _emitChanged(p);
      return {'adopted': true};
    }
    final playlistId = _requireString(call.args['playlistId'], 'playlistId');
    final pos = _wholeNumber(call.args['positionMs']);
    if (itemId is! String || pos == null || pos < 0) {
      throw const HubError(
        HubErrorCode.invalid,
        'itemId or positionMs invalid',
      );
    }
    final ids = await playlists.itemIds(playlistId);
    final at = ids?.indexOf(itemId) ?? -1;
    if (at < 0) return {'adopted': false}; // Stale: the item is gone.
    final dur = _wholeNumber(call.args['durationMs']);
    p
      ..playlistId = playlistId
      ..index = at
      ..itemId = itemId
      ..state = state as String
      ..positionMs = pos
      ..startedAt = state == PlayerState.playing ? _nowMs - pos : null
      ..durationMs = (dur != null && dur > 0) ? dur : null
      ..ignorePositionUntil = 0;
    if (call.args['muted'] is bool) p.muted = call.args['muted'] as bool;
    _emitChanged(p);
    return {'adopted': true};
  });

  /// The TV's report is older than a command: put the TV right.
  Future<void> _reconcile(String displayId, _Player p) async {
    final item = p.itemId;
    if (item == null) {
      display.sendControl(displayId, action: 'stop');
      return;
    }
    final playlistId = p.playlistId;
    if (playlistId != null && await unplayableReason?.call(item) != null) {
      // The item became unplayable while the TV was away: move on.
      final ids = await playlists.itemIds(playlistId);
      if (ids == null || ids.isEmpty) {
        _goIdle(displayId, p);
      } else {
        await _startFrom(
          displayId,
          p,
          playlistId,
          ids,
          _stepIndex(p, ids, 1),
          1,
        );
      }
      return;
    }
    display.sendLoad(
      displayId,
      itemId: item,
      startAt: _positionNow(p),
      muted: p.muted,
    );
    if (p.state == PlayerState.paused) {
      display.sendControl(displayId, action: 'pause', positionMs: p.positionMs);
    }
  }

  Future<Object?> _ended(HubCall call) => _serialized(() async {
    _requireDisplay(call);
    final itemId = call.args['itemId'];
    if (itemId is! String || itemId.isEmpty) {
      throw const HubError(HubErrorCode.invalid, 'itemId is missing');
    }
    final p = _playerOf(call);
    // A duplicate or late `ended` must not skip an item.
    if (p.itemId != itemId || p.playlistId == null) return {'moved': false};
    final ids = await playlists.itemIds(p.playlistId!);
    if (ids == null || ids.isEmpty) {
      p
        ..itemId = null
        ..state = PlayerState.idle
        ..positionMs = 0
        ..startedAt = null;
      _emitChanged(p);
      display.sendControl(call.device.id, action: 'stop');
      return {'moved': false};
    }
    final moved = await _startFrom(
      call.device.id,
      p,
      p.playlistId!,
      ids,
      _stepIndex(p, ids, 1),
      1,
    );
    return {'moved': moved};
  });

  /// The library removed [itemId]: a player that is on it moves on as if the
  /// item had ended (or goes idle when its playlist is empty now). Queued
  /// items simply drop out of the playlist.
  Future<void> itemRemoved(String itemId) => _serialized(() async {
    if (_disposed) return;
    for (final e in _players.entries.toList()) {
      final p = e.value;
      final playlistId = p.playlistId;
      if (p.itemId != itemId || playlistId == null) continue;
      final ids = await playlists.itemIds(playlistId);
      if (ids == null || ids.isEmpty) {
        p
          ..itemId = null
          ..state = PlayerState.idle
          ..positionMs = 0
          ..startedAt = null;
        _emitChanged(p);
        display.sendControl(e.key, action: 'stop');
      } else {
        await _startFrom(e.key, p, playlistId, ids, _stepIndex(p, ids, 1), 1);
      }
    }
  });

  // ---- module plumbing ----

  @override
  Future<Map<String, Object?>> snapshotFor(DeviceInfo device) async {
    final key = display.onlineDisplayId ?? _players.keys.firstOrNull;
    final p = key == null ? null : _players[key];
    return {..._json(p ?? _Player()), 'at': _nowMs};
  }

  @override
  Future<void> onPresenceChanged(Set<String> onlineDeviceIds) =>
      _serialized(() async {
        if (_disposed) return;
        try {
          final known = {for (final r in await db.displays()) r.id};
          _players.removeWhere((key, _) => !known.contains(key));
        } catch (_) {
          // The database may already be closed while the server stops.
        }
        for (final e in _players.entries) {
          final p = e.value;
          final on = onlineDeviceIds.contains(e.key);
          if (p.online && !on) {
            // The TV left: freeze the clock instead of letting it run.
            if (p.state == PlayerState.playing) {
              p
                ..positionMs = _positionNow(p)
                ..state = PlayerState.paused
                ..startedAt = null;
              _emitChanged(p);
            }
          } else if (!p.online && on) {
            p.commandSinceConnect = false;
          }
          p.online = on;
        }
      });

  @override
  Future<void> dispose() async {
    _disposed = true;
    await _events.close();
  }
}
