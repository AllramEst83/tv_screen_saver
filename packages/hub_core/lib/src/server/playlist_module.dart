import 'dart:async';

import '../protocol.dart';
import 'hub_module.dart';
import 'playlist_store.dart';

/// The `playlist` module.
///
/// Requests: `playlist.create {name, items?, shuffle?, imageSeconds?,
/// transition?, kenBurns?, muted?}` and `playlist.update {id, ...}` (any
/// paired phone) answer `{playlist}`; `playlist.delete {id}` is owner only.
/// Events `playlist.changed {playlist}` and `playlist.removed {id}`. Snapshot
/// `{playlists[]}`.
class PlaylistModule implements HubModule {
  PlaylistModule(this.store);

  final PlaylistStore store;

  @override
  String get id => 'playlist';

  @override
  Stream<HubOutboundEvent> get events => store.events.map(
    (e) => HubOutboundEvent.broadcast(module: id, kind: e.kind, data: e.data),
  );

  @override
  Map<String, HubHandlerSpec> get handlers => {
    'playlist.create': HubHandlerSpec(handler: _create),
    'playlist.update': HubHandlerSpec(handler: _update),
    'playlist.delete': HubHandlerSpec(handler: _delete, requireOwner: true),
  };

  static const _envelope = {'t', 'rid', 'op', 'id'};

  Map<String, Object?> _fields(HubCall call) => {
    for (final e in call.args.entries)
      if (!_envelope.contains(e.key)) e.key: e.value,
  };

  String _id(HubCall call) {
    final v = call.args['id'];
    if (v is! String || v.isEmpty) {
      throw const HubError(HubErrorCode.invalid, 'id is missing');
    }
    return v;
  }

  Future<Object?> _create(HubCall call) async => {
    'playlist': await store.create(_fields(call)),
  };

  Future<Object?> _update(HubCall call) async => {
    'playlist': await store.update(_id(call), _fields(call)),
  };

  Future<Object?> _delete(HubCall call) async {
    if (!await store.delete(_id(call))) {
      throw const HubError(HubErrorCode.notFound, 'Unknown playlist');
    }
    return const <String, Object?>{};
  }

  @override
  Future<Map<String, Object?>> snapshotFor(DeviceInfo device) async => {
    'playlists': await store.list(),
  };

  @override
  Future<void> onPresenceChanged(Set<String> onlineDeviceIds) async {}

  @override
  Future<void> dispose() => store.dispose();
}
