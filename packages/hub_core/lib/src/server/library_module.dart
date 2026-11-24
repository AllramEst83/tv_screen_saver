import 'dart:async';

import '../protocol.dart';
import 'hub_module.dart';
import 'library_store.dart';

/// The `library` module.
///
/// Requests: `library.exists {sha256}` -> `{exists, id?}`,
/// `library.rename {id, name}` (any paired device), `library.delete {id}`
/// (owner only). Events `library.added`, `library.updated` (item) and
/// `library.removed {id}`. Snapshot `{items[], storage: {usedBytes, capBytes}}`.
class LibraryModule implements HubModule {
  LibraryModule(this.store);

  final LibraryStore store;

  @override
  String get id => 'library';

  @override
  Stream<HubOutboundEvent> get events => store.events.map(
    (e) => HubOutboundEvent.broadcast(module: id, kind: e.kind, data: e.data),
  );

  @override
  Map<String, HubHandlerSpec> get handlers => {
    'library.exists': HubHandlerSpec(handler: _exists),
    'library.rename': HubHandlerSpec(handler: _rename),
    'library.delete': HubHandlerSpec(handler: _delete, requireOwner: true),
  };

  String _requireId(HubCall call) {
    final v = call.args['id'];
    if (v is! String || v.isEmpty) {
      throw const HubError(HubErrorCode.invalid, 'id is missing');
    }
    return v;
  }

  Future<Object?> _exists(HubCall call) async {
    final sha = call.args['sha256'];
    if (!isValidSha256(sha)) {
      throw const HubError(
        HubErrorCode.invalid,
        'sha256 must be 64 hex digits',
      );
    }
    final row = await store.itemBySha(sha as String);
    return {'exists': row != null, 'id': ?row?.id};
  }

  Future<Object?> _rename(HubCall call) async {
    final id = _requireId(call);
    final raw = call.args['name'];
    final name = raw is String ? raw.trim() : '';
    if (name.isEmpty || name.length > 255) {
      throw const HubError(
        HubErrorCode.invalid,
        'name must be 1-255 characters',
      );
    }
    final row = await store.rename(id, name);
    if (row == null) {
      throw const HubError(HubErrorCode.notFound, 'Unknown item');
    }
    return null;
  }

  Future<Object?> _delete(HubCall call) async {
    final id = _requireId(call);
    if (!await store.deleteItem(id)) {
      throw const HubError(HubErrorCode.notFound, 'Unknown item');
    }
    return null;
  }

  @override
  Future<Map<String, Object?>> snapshotFor(DeviceInfo device) =>
      store.snapshot();

  @override
  Future<void> onPresenceChanged(Set<String> onlineDeviceIds) async {}

  @override
  Future<void> dispose() async {}
}
