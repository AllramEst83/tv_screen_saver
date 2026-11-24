import '../db/hub_database.dart';

/// Role of a paired device. The first paired phone is the [owner]; later
/// phones are [controller]s. The TV is the [display]: never owner, but its
/// requests count as owner-equivalent (physical presence).
enum DeviceRole {
  owner,
  controller,
  display;

  static DeviceRole parse(String? raw) => switch (raw) {
    'owner' => DeviceRole.owner,
    'display' => DeviceRole.display,
    _ => DeviceRole.controller,
  };
}

/// Immutable value object for a paired device sent over Protocol v1.
class DeviceInfo {
  const DeviceInfo({
    required this.id,
    required this.name,
    required this.role,
    this.online = false,
  });

  /// The TV's own remote control, acting in-process as an owner.
  static const tv = DeviceInfo(
    id: '__tv__',
    name: 'TV',
    role: DeviceRole.owner,
    online: true,
  );

  final String id;
  final String name;
  final DeviceRole role;
  final bool online;

  bool get isOwner => role == DeviceRole.owner;
  bool get isDisplay => role == DeviceRole.display;

  /// Owner or display: may do owner-only actions.
  bool get isOwnerEquivalent => isOwner || isDisplay;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'role': role.name,
    'online': online,
  };

  DeviceInfo copyWith({String? name, DeviceRole? role, bool? online}) =>
      DeviceInfo(
        id: id,
        name: name ?? this.name,
        role: role ?? this.role,
        online: online ?? this.online,
      );

  factory DeviceInfo.fromRow(DeviceRow row, {bool online = false}) =>
      DeviceInfo(
        id: row.id,
        name: row.name,
        role: DeviceRole.parse(row.role),
        online: online,
      );

  factory DeviceInfo.fromJson(Map<String, dynamic> json) => DeviceInfo(
    id: json['id'] as String? ?? '',
    name: json['name'] as String? ?? '',
    role: DeviceRole.parse(json['role'] as String?),
    online: json['online'] == true,
  );
}

/// Domain error returned to the caller as `{t: "err", rid, code, msg, ...extra}`.
class HubError implements Exception {
  const HubError(this.code, [this.message, this.extra = const {}]);

  final String code;
  final String? message;
  final Map<String, Object?> extra;

  @override
  String toString() => 'HubError($code, $message)';
}

/// Context passed into a [HubModule] handler invocation.
class HubCall {
  const HubCall({
    required this.type,
    required this.device,
    required this.args,
    required this.connectionId,
    this.rid,
  });

  final String type;
  final DeviceInfo device;
  final Map<String, dynamic> args;
  final String connectionId;
  final int? rid;
}

typedef HubHandler = Future<Object?> Function(HubCall call);

/// Declares a message handler and its required role.
class HubHandlerSpec {
  const HubHandlerSpec({
    required this.handler,
    this.requireOwner = false,
    this.hot = false,
  });

  final HubHandler handler;
  final bool requireOwner;

  /// High-frequency, latency-critical handler (live gestures). The server
  /// skips the per-frame device DB refresh and uses the connection's cached
  /// device, so no database work happens before the handler runs.
  final bool hot;
}

/// Fan-out destination for outbound events emitted by a [HubModule].
enum EventTargetKind {
  /// Broadcast to all ready sockets and increments the monotonic `rev`.
  broadcast,

  /// Sent only to sockets bound to the target device (no `rev` change).
  targetedDevice,

  /// Sent immediately to all ready sockets without a `rev` change, optionally
  /// excluding the sender (hot frames).
  unrevisionedBroadcast,
}

/// An event emitted by a [HubModule] for the server to dispatch.
class HubOutboundEvent {
  const HubOutboundEvent._({
    required this.target,
    required this.module,
    required this.kind,
    required this.data,
    this.targetDeviceId,
    this.rawFrameType,
    this.excludeConnectionId,
  });

  /// Broadcasts `{t: "event", rev, module, kind, data}` to every ready client.
  factory HubOutboundEvent.broadcast({
    required String module,
    required String kind,
    required Map<String, Object?> data,
  }) => HubOutboundEvent._(
    target: EventTargetKind.broadcast,
    module: module,
    kind: kind,
    data: data,
  );

  /// Sends a raw frame `{t: rawFrameType, ...data}` only to sockets of
  /// [deviceId].
  factory HubOutboundEvent.targeted({
    required String module,
    required String rawFrameType,
    required String deviceId,
    required Map<String, Object?> data,
  }) => HubOutboundEvent._(
    target: EventTargetKind.targetedDevice,
    module: module,
    kind: rawFrameType,
    rawFrameType: rawFrameType,
    targetDeviceId: deviceId,
    data: data,
  );

  /// Sends an unrevisioned frame `{t: rawFrameType, ...data}` to all ready
  /// sockets except [excludeConnectionId].
  factory HubOutboundEvent.unrevisioned({
    required String module,
    required String rawFrameType,
    required Map<String, Object?> data,
    String? excludeConnectionId,
  }) => HubOutboundEvent._(
    target: EventTargetKind.unrevisionedBroadcast,
    module: module,
    kind: rawFrameType,
    rawFrameType: rawFrameType,
    data: data,
    excludeConnectionId: excludeConnectionId,
  );

  final EventTargetKind target;
  final String module;
  final String kind;
  final Map<String, Object?> data;
  final String? targetDeviceId;
  final String? rawFrameType;
  final String? excludeConnectionId;
}

/// Pluggable domain module hosted inside the server (`devices` today; scene,
/// library and settings later).
abstract class HubModule {
  String get id;
  Map<String, HubHandlerSpec> get handlers;
  Future<Map<String, Object?>> snapshotFor(DeviceInfo device);
  Stream<HubOutboundEvent> get events;

  /// Called whenever a client becomes ready or disconnects.
  Future<void> onPresenceChanged(Set<String> onlineDeviceIds) async {}

  /// Optional cleanup when the server stops.
  Future<void> dispose() async {}
}
