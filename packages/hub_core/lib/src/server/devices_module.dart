import 'dart:async';

import '../protocol.dart';
import '../db/hub_database.dart';
import 'hub_module.dart';

/// Built-in module listing paired devices and handling rename and forget.
///
/// - snapshot: `{devices: [{id, name, role, online}, ...]}`
/// - `device.rename {name}`: any device renames itself
/// - `device.forget {deviceId}`: owner only; the device's pairings are deleted
///   and its sockets closed
/// - `devices.startPairing` / `devices.cancelPairing`: display only
/// - `devices.approveDisplay {requestId}`: any paired phone
/// - `devices.forgetAll`: owner or display; deletes all phone pairings
/// - event `devices.changed {devices}`: on connect, disconnect, rename, forget
class DevicesModule implements HubModule {
  DevicesModule({
    required this.db,
    required this.onForgetDevice,
    this.onStartPairing,
    this.onCancelPairing,
    this.onApproveDisplay,
    this.onForgetAllPhones,
  });

  final HubDatabase db;

  /// Deletes the device's pairings and drops its sockets (provided by the
  /// server).
  final Future<void> Function(String deviceId) onForgetDevice;

  /// Opens a pairing session relayed to the calling display connection.
  final Future<void> Function(String connectionId)? onStartPairing;
  final Future<void> Function(String connectionId)? onCancelPairing;

  /// Approves a waiting display; returns false for an unknown request.
  final Future<bool> Function(String requestId)? onApproveDisplay;

  /// Deletes every phone pairing and closes phone sockets.
  final Future<void> Function(String callerConnectionId)? onForgetAllPhones;

  static const maxNameLength = 40;

  final _events = StreamController<HubOutboundEvent>.broadcast();
  Set<String> _online = const {};
  bool _disposed = false;

  @override
  String get id => 'devices';

  @override
  Stream<HubOutboundEvent> get events => _events.stream;

  @override
  Map<String, HubHandlerSpec> get handlers => {
    'device.rename': HubHandlerSpec(handler: _rename),
    'device.forget': HubHandlerSpec(handler: _forget, requireOwner: true),
    'devices.startPairing': HubHandlerSpec(handler: _startPairing),
    'devices.cancelPairing': HubHandlerSpec(handler: _cancelPairing),
    'devices.approveDisplay': HubHandlerSpec(handler: _approveDisplay),
    'devices.forgetAll': HubHandlerSpec(
      handler: _forgetAll,
      requireOwner: true,
    ),
  };

  void _requireDisplay(HubCall call) {
    if (!call.device.isDisplay) {
      throw const HubError(HubErrorCode.forbidden, 'Only the TV can do this');
    }
  }

  Future<Object?> _startPairing(HubCall call) async {
    _requireDisplay(call);
    final fn = onStartPairing;
    if (fn == null) {
      throw const HubError(
        HubErrorCode.unavailable,
        'Pairing is not available',
      );
    }
    await fn(call.connectionId);
    return null;
  }

  Future<Object?> _cancelPairing(HubCall call) async {
    _requireDisplay(call);
    await onCancelPairing?.call(call.connectionId);
    return null;
  }

  Future<Object?> _approveDisplay(HubCall call) async {
    if (call.device.isDisplay) {
      throw const HubError(
        HubErrorCode.forbidden,
        'Only a paired phone can approve a TV',
      );
    }
    final requestId = call.args['requestId'];
    if (requestId is! String || requestId.isEmpty) {
      throw const HubError(HubErrorCode.invalid, 'requestId is missing');
    }
    final ok = await onApproveDisplay?.call(requestId) ?? false;
    if (!ok) {
      throw const HubError(HubErrorCode.notFound, 'Unknown or expired request');
    }
    return {'requestId': requestId};
  }

  Future<Object?> _forgetAll(HubCall call) async {
    final fn = onForgetAllPhones;
    if (fn == null) {
      throw const HubError(HubErrorCode.unavailable, 'Not available');
    }
    await fn(call.connectionId);
    return null;
  }

  Future<List<Map<String, Object?>>> _deviceList() async => [
    for (final r in await db.allDevices())
      DeviceInfo.fromRow(r, online: _online.contains(r.id)).toJson(),
  ];

  @override
  Future<Map<String, Object?>> snapshotFor(DeviceInfo device) async => {
    'devices': await _deviceList(),
  };

  Future<void> _emitChanged() async {
    if (_disposed || _events.isClosed) return;
    try {
      final list = await _deviceList();
      if (_disposed || _events.isClosed) return;
      _events.add(
        HubOutboundEvent.broadcast(
          module: id,
          kind: 'devices.changed',
          data: {'devices': list},
        ),
      );
    } catch (_) {
      // The database may already be closed while the server shuts down.
    }
  }

  @override
  Future<void> onPresenceChanged(Set<String> onlineDeviceIds) async {
    _online = Set.of(onlineDeviceIds);
    await _emitChanged();
  }

  Future<Object?> _rename(HubCall call) async {
    final raw = call.args['name'];
    final name = raw is String ? raw.trim() : '';
    if (name.isEmpty || name.length > maxNameLength) {
      throw const HubError(
        HubErrorCode.invalid,
        'Name must be 1-$maxNameLength characters',
      );
    }
    if (call.device.id == DeviceInfo.tv.id) {
      throw const HubError(HubErrorCode.invalid, 'The TV has no device name');
    }
    await db.renameDevice(call.device.id, name);
    await _emitChanged();
    return {'name': name};
  }

  Future<Object?> _forget(HubCall call) async {
    final target = call.args['deviceId'];
    if (target is! String || target.isEmpty) {
      throw const HubError(HubErrorCode.invalid, 'deviceId is missing');
    }
    final row = await db.getDevice(target);
    if (row == null) {
      throw const HubError(HubErrorCode.notFound, 'Unknown device');
    }
    if (target == call.device.id || row.role == DeviceRole.owner.name) {
      throw const HubError(
        HubErrorCode.forbidden,
        'The owner cannot be forgotten this way',
      );
    }
    // The server notifies presence afterwards, which emits `devices.changed`.
    await onForgetDevice(target);
    return {'deviceId': target};
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    await _events.close();
  }
}
