import 'dart:async';
import 'dart:convert';

import '../db/hub_database.dart';
import '../protocol.dart';
import 'hub_module.dart';

/// The `display` module: what the TV can do, and the frames the Pi sends it.
///
/// - `display.capabilities {decoders[], hdr[], render, panel}`: display only,
///   on every connect; kept per display id in memory
/// - event `display.changed {online}`: the display connected or left
/// - targeted frames to the display: `display.load {itemId, variant, startAt,
///   muted}` and `display.control {action, positionMs?, muted?}`
///   (`display.pairing` comes from the server, see `HubServer`)
class DisplayModule implements HubModule {
  DisplayModule({required this.db, this.onCapabilitiesChanged});

  final HubDatabase db;

  /// Called when a display reports capabilities that differ from what was
  /// stored (also the first report). Errors are ignored.
  Future<void> Function()? onCapabilitiesChanged;

  static const _maxEntries = 128;
  static const _maxEntryLength = 256;

  final _events = StreamController<HubOutboundEvent>.broadcast();
  final Map<String, Map<String, Object?>> _capabilities = {};
  String? _onlineDisplayId;
  bool _disposed = false;

  @override
  String get id => 'display';

  @override
  Stream<HubOutboundEvent> get events => _events.stream;

  /// Id of the display that is connected right now, or null.
  String? get onlineDisplayId => _onlineDisplayId;

  /// The capabilities of the connected display, else of the last one that
  /// reported; null when none has reported yet.
  Map<String, Object?>? get currentCapabilities {
    final online = _onlineDisplayId;
    if (online != null && _capabilities[online] != null) {
      return _capabilities[online];
    }
    return _capabilities.isEmpty ? null : _capabilities.values.last;
  }

  /// The capabilities [displayId] sent on its last connect, or null.
  Map<String, Object?>? capabilitiesFor(String displayId) =>
      _capabilities[displayId];

  @override
  Map<String, HubHandlerSpec> get handlers => {
    'display.capabilities': HubHandlerSpec(handler: _setCapabilities),
  };

  List<String> _stringList(Object? v, String field) {
    if (v is! List ||
        v.length > _maxEntries ||
        v.any((e) => e is! String || e.length > _maxEntryLength)) {
      throw HubError(
        HubErrorCode.invalid,
        '$field must be a list of up to $_maxEntries short strings',
      );
    }
    return List<String>.of(v.cast<String>());
  }

  Object? _sizeField(Object? v, String field) {
    if (v == null || v is String || v is Map) return v;
    throw HubError(HubErrorCode.invalid, '$field must be a string or object');
  }

  Future<Object?> _setCapabilities(HubCall call) async {
    if (!call.device.isDisplay) {
      throw const HubError(HubErrorCode.forbidden, 'Only the TV can do this');
    }
    final caps = <String, Object?>{
      'decoders': _stringList(call.args['decoders'], 'decoders'),
      'hdr': _stringList(call.args['hdr'], 'hdr'),
      'render': _sizeField(call.args['render'], 'render'),
      'panel': _sizeField(call.args['panel'], 'panel'),
    };
    final old = _capabilities.remove(call.device.id);
    _capabilities[call.device.id] = caps;
    if (old == null || jsonEncode(old) != jsonEncode(caps)) {
      final cb = onCapabilitiesChanged;
      if (cb != null) cb().then<void>((_) {}, onError: (Object _) {});
    }
    return null;
  }

  /// Tells [displayId] to load an item. [startAt] is a position in
  /// milliseconds.
  void sendLoad(
    String displayId, {
    required String itemId,
    int startAt = 0,
    bool muted = false,
    Map<String, Object?> extra = const {},
  }) {
    _send(displayId, 'display.load', {
      'itemId': itemId,
      'variant': 'full',
      'startAt': startAt,
      'muted': muted,
      ...extra,
    });
  }

  /// Gives [displayId] the order and kinds of the current playlist so it can
  /// keep looping what it has cached when the Pi is out of reach.
  void sendPlaylist(String displayId, Map<String, Object?> data) =>
      _send(displayId, 'display.playlist', data);

  /// Tells [displayId] which items will play next so it can cache them, and
  /// how many bytes its cache may hold.
  void sendPrefetch(
    String displayId, {
    required List<String> itemIds,
    int? cacheBytes,
  }) {
    _send(displayId, 'display.prefetch', {
      'itemIds': itemIds,
      'cacheBytes': ?cacheBytes,
    });
  }

  /// Tells [displayId] to pause, resume, seek or change mute.
  void sendControl(
    String displayId, {
    required String action,
    int? positionMs,
    bool? muted,
  }) {
    _send(displayId, 'display.control', {
      'action': action,
      'positionMs': ?positionMs,
      'muted': ?muted,
    });
  }

  void _send(String displayId, String frame, Map<String, Object?> data) {
    if (_disposed || _events.isClosed) return;
    _events.add(
      HubOutboundEvent.targeted(
        module: id,
        rawFrameType: frame,
        deviceId: displayId,
        data: data,
      ),
    );
  }

  @override
  Future<Map<String, Object?>> snapshotFor(DeviceInfo device) async => {
    'online': _onlineDisplayId != null,
  };

  Future<void> _presenceQueue = Future.value();

  /// Calls are chained so overlapping presence changes finish in order.
  @override
  Future<void> onPresenceChanged(Set<String> onlineDeviceIds) {
    final run = _presenceQueue.then((_) => _updatePresence(onlineDeviceIds));
    _presenceQueue = run.then<void>((_) {}, onError: (Object _) {});
    return run;
  }

  Future<void> _updatePresence(Set<String> onlineDeviceIds) async {
    if (_disposed) return;
    final List<DeviceRow> rows;
    try {
      rows = await db.displays();
    } catch (_) {
      return; // The database may already be closed while the server stops.
    }
    if (_disposed) return;
    final known = {for (final r in rows) r.id};
    _capabilities.removeWhere((key, _) => !known.contains(key));
    String? online;
    for (final r in rows) {
      if (onlineDeviceIds.contains(r.id)) online = r.id;
    }
    final changed = (online != null) != (_onlineDisplayId != null);
    _onlineDisplayId = online;
    if (changed && !_events.isClosed) {
      _events.add(
        HubOutboundEvent.broadcast(
          module: id,
          kind: 'display.changed',
          data: {'online': online != null},
        ),
      );
    }
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    await _events.close();
  }
}
