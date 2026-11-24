import 'dart:async';

import 'hub_module.dart';
import 'settings_store.dart';

/// The `settings` module.
///
/// - `settings.update {...}`: owner or display; partial, validated, stored
/// - snapshot `{values, limits}`; everyone may read
/// - event `settings.changed {values}`
class SettingsModule implements HubModule {
  SettingsModule(this.store);

  final SettingsStore store;

  @override
  String get id => 'settings';

  @override
  Stream<HubOutboundEvent> get events => store.changes.map(
    (v) => HubOutboundEvent.broadcast(
      module: id,
      kind: 'settings.changed',
      data: {'values': v},
    ),
  );

  @override
  Map<String, HubHandlerSpec> get handlers => {
    'settings.update': HubHandlerSpec(handler: _update, requireOwner: true),
  };

  /// Frame fields that are not settings.
  static const _envelope = {'t', 'rid', 'op'};

  Future<Object?> _update(HubCall call) async => {
    'values': await store.update({
      for (final e in call.args.entries)
        if (!_envelope.contains(e.key)) e.key: e.value,
    }),
  };

  @override
  Future<Map<String, Object?>> snapshotFor(DeviceInfo device) async =>
      store.snapshot;

  @override
  Future<void> onPresenceChanged(Set<String> onlineDeviceIds) async {}

  @override
  Future<void> dispose() async {}
}
