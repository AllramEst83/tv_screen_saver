import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:hub_core/hub_core.dart';

import '../shared/multicast_lock.dart';
import 'now_playing.dart';
import 'upload/uploader.dart';

/// Which top-level screen the phone shows.
enum PhoneScreen { loading, connect, pin, home }

/// Result of handing a scanned QR code to the controller.
enum QrOutcome {
  /// Not a TV Saver pairing code: stay on the scanner.
  invalid,

  /// A connection attempt started: leave the scanner and watch the state.
  started,
}

/// How the phone is linked to the Pi, for the drawer header and the banner.
enum LinkStatus {
  /// Connected and the TV is there.
  connected,

  /// Connected to the Pi, but the TV is not connected to it.
  tvOff,

  /// The connection dropped and the app is trying again.
  reconnecting,

  /// The Pi did not answer; the app stops trying until Retry.
  offline,

  /// The Pi answered but the TV Saver server is not running on it.
  serverDown,
}

/// The outcome of a settings or rename request.
class ChangeResult {
  const ChangeResult.ok() : ok = true, field = null, message = null;
  const ChangeResult.failed(this.message, {this.field}) : ok = false;

  final bool ok;

  /// The setting key the message belongs to, when the Pi named one.
  final String? field;
  final String? message;
}

/// A TV that waits for a phone to approve it (`devices.approvalRequested`).
class PendingApproval {
  const PendingApproval(this.requestId, this.name);

  final String requestId;
  final String name;
}

/// Phone-side state over [HubClient]: which screen to show, the paired device
/// list, the Wi-Fi multicast lock and the saved pairing.
class PhoneController extends ChangeNotifier {
  PhoneController({
    required this.client,
    required this.store,
    MulticastLock? lock,
  }) : _lock = lock ?? MulticastLock() {
    client.state.addListener(_onHubState);
    _subs = [
      client.snapshots.listen(_onSnapshot),
      client.events.listen(_onEvent),
    ];
  }

  final HubClient client;
  final HubTokenStore store;
  final MulticastLock _lock;
  late final List<StreamSubscription<Map<String, dynamic>>> _subs;

  bool _starting = false;
  bool _started = false;
  bool _foreground = true;
  bool _hasPairing = false;
  bool _scanning = false;
  bool _lockHeld = false;
  bool _disposed = false;
  List<DeviceInfo> _devices = const [];
  NowPlaying _nowPlaying = const NowPlaying();
  bool? _displayOnline;
  bool _tvNotConnected = false;
  String? _playerError;
  PendingApproval? _approval;
  bool _wasConnected = false;
  bool _closing = false;
  Map<String, Object?> _settings = const {};
  Map<String, Map<String, int>> _limits = const {};
  final Map<String, String> _itemNames = {};
  final Map<String, int> _itemDurations = {};
  final Map<String, Map<String, Object?>> _items = {};
  ImageUploader? _uploader;
  int _usedBytes = 0;
  int _capBytes = 0;
  bool _hasLibrary = false;

  HubClientState get hub => client.state.value;

  /// A pairing is saved on this phone (the app will reconnect on its own).
  bool get hasPairing => _hasPairing;

  List<DeviceInfo> get devices => _devices;

  /// This phone, with the name and role the Pi lists now (a rename shows up
  /// here without reconnecting).
  DeviceInfo? get me {
    final mine = hub.device;
    if (mine == null) return null;
    for (final d in _devices) {
      if (d.id == mine.id) return d;
    }
    return mine;
  }

  bool get lockHeld => _lockHeld;

  /// What the TV is playing (the `player` module).
  NowPlaying get nowPlaying => _nowPlaying;

  /// The Pi has no TV connected: the last command got `unavailable`, or the
  /// `display` module says so.
  bool get tvNotConnected => _tvNotConnected || _displayOnline == false;

  /// A new TV asks to be let in; the Home screen shows "Approve this TV?".
  PendingApproval? get pendingApproval => _approval;

  /// The message of the last player command that failed for another reason.
  String? get playerError => _playerError;

  /// The playing position now, from the Pi's clock.
  int get positionMs => _nowPlaying.positionAt(client.tvNowMs());

  PhoneScreen get screen {
    if (!_started) return PhoneScreen.loading;
    return switch (hub.phase) {
      HubConnectionPhase.connected => PhoneScreen.home,
      HubConnectionPhase.awaitingPin => PhoneScreen.pin,
      // A phone that was connected stays in the app while the link comes
      // back; the banner says what is going on.
      HubConnectionPhase.connecting ||
      HubConnectionPhase.reconnecting ||
      HubConnectionPhase.offline ||
      HubConnectionPhase.appNotOpen when _wasConnected && _hasPairing =>
        PhoneScreen.home,
      _ => PhoneScreen.connect,
    };
  }

  /// The link to the Pi, for the drawer header and the status banner.
  LinkStatus get linkStatus => switch (hub.phase) {
    HubConnectionPhase.connected =>
      tvNotConnected ? LinkStatus.tvOff : LinkStatus.connected,
    HubConnectionPhase.connecting ||
    HubConnectionPhase.reconnecting => LinkStatus.reconnecting,
    HubConnectionPhase.appNotOpen => LinkStatus.serverDown,
    _ => LinkStatus.offline,
  };

  /// Settings are readable but cannot be changed while the Pi is away.
  bool get isLinked => hub.phase == HubConnectionPhase.connected;

  /// Only the owner (or the TV) may change settings, and only while linked.
  bool get canChangeSettings => isLinked && (me?.isOwnerEquivalent ?? false);

  bool get isOwner => me?.isOwner ?? false;

  /// The Pi's stored settings (`settings` module); empty until the first
  /// snapshot.
  Map<String, Object?> get settings => _settings;
  bool get hasSettings => _settings.isNotEmpty;

  int? settingInt(String key) => _settings[key] as int?;
  bool settingBool(String key, {bool or = false}) =>
      _settings[key] as bool? ?? or;
  String? settingString(String key) => _settings[key] as String?;

  /// `{min, max}` the Pi accepts for [key], or null.
  Map<String, int>? limitFor(String key) => _limits[key];

  /// Bytes the library (and unfinished uploads) take on the Pi.
  int get storageUsedBytes => _usedBytes;

  /// The Pi's storage limit in bytes; 0 while it is not known.
  int get storageCapBytes => _capBytes;
  bool get hasLibrary => _hasLibrary;

  /// The stored library items, by name (case-insensitive).
  List<Map<String, Object?>> get libraryItems {
    final list = _items.values.toList()
      ..sort(
        (a, b) => '${a['name']}'.toLowerCase().compareTo(
          '${b['name']}'.toLowerCase(),
        ),
      );
    return list;
  }

  /// Owner and controller phones may add pictures.
  bool get canUpload => isLinked && me?.role != DeviceRole.display;

  /// The upload queue; it lives as long as the app, so it keeps running when
  /// the Library screen is closed.
  ImageUploader get uploader => _uploader ??= ImageUploader(
    request: (type, args) => client.request(type, args),
    open: client.openAuthorized,
  );

  /// The name of a library item; the id when it is not known.
  String nameOfItem(String id) => _itemNames[id] ?? id;

  /// Length of a library video in milliseconds, or null (photo, unknown).
  int? durationOf(String id) => _itemDurations[id];

  /// The Pi says no TV is connected (not just a failed command).
  bool get displayKnownOffline => _displayOnline == false;

  /// Status line for the Connect screen, per [HubConnectionPhase].
  String get statusText {
    final h = hub;
    final name = h.hubName ?? 'TV Saver';
    return switch (h.phase) {
      HubConnectionPhase.connecting => 'Connecting…',
      HubConnectionPhase.reconnecting => 'Looking for $name…',
      HubConnectionPhase.offline => h.lastError ?? HubMessages.tvNotFound,
      HubConnectionPhase.appNotOpen => HubMessages.appNotOpen,
      HubConnectionPhase.wrongTv => HubMessages.wrongTv,
      HubConnectionPhase.needsTvUpdate => HubMessages.upgradeTv,
      HubConnectionPhase.replaced => HubMessages.replaced,
      HubConnectionPhase.disconnected =>
        h.lastError ??
            (_hasPairing
                ? HubMessages.notConnected
                : 'Scan the QR code on the TV to pair this phone.'),
      _ => '',
    };
  }

  static const _unreachable = "Couldn't reach the Pi. Try again.";

  /// Changes settings on the Pi (owner only). A refusal names the field.
  Future<ChangeResult> updateSettings(Map<String, Object?> patch) async {
    try {
      final r = await client.request('settings.update', patch);
      final values = r['values'];
      if (values is Map) {
        _settings = {..._settings, ...Map<String, Object?>.from(values)};
        if (!_disposed) notifyListeners();
      }
      return const ChangeResult.ok();
    } on HubError catch (e) {
      final field = e.extra['field'];
      return ChangeResult.failed(
        e.code == HubErrorCode.forbidden
            ? 'Only the owner can change this'
            : (e.message ?? 'The change was refused'),
        field: field is String ? field : null,
      );
    } catch (_) {
      return const ChangeResult.failed(_unreachable);
    }
  }

  /// Renames this phone (1-40 characters after trimming).
  Future<ChangeResult> renameThisPhone(String raw) async {
    final name = raw.trim();
    if (name.isEmpty) return const ChangeResult.failed('Enter a name');
    if (name.length > maxDeviceNameLength) {
      return const ChangeResult.failed(
        'Use $maxDeviceNameLength characters or fewer',
      );
    }
    try {
      await client.request('device.rename', {'name': name});
      return const ChangeResult.ok();
    } on HubError catch (e) {
      return ChangeResult.failed(e.message ?? 'The name was refused');
    } catch (_) {
      return const ChangeResult.failed(_unreachable);
    }
  }

  static const maxDeviceNameLength = 40;

  /// Removes another phone's pairing (owner only).
  Future<ChangeResult> forgetDevice(String deviceId) async {
    try {
      await client.request('device.forget', {'deviceId': deviceId});
      return const ChangeResult.ok();
    } on HubError catch (e) {
      return ChangeResult.failed(e.message ?? 'The phone was not removed');
    } catch (_) {
      return const ChangeResult.failed(_unreachable);
    }
  }

  /// Removes every phone pairing, this one included (owner only).
  Future<ChangeResult> forgetAllPhones() async {
    try {
      await client.request('devices.forgetAll');
      return const ChangeResult.ok();
    } on HubError catch (e) {
      return ChangeResult.failed(e.message ?? 'The phones were not removed');
    } catch (_) {
      return const ChangeResult.failed(_unreachable);
    }
  }

  /// Close app: releases the multicast lock, disconnects and leaves. The
  /// pairing stays saved, so the next launch reconnects by itself.
  Future<void> closeApp() async {
    if (_closing) return; // a second tap while it closes does nothing
    _closing = true;
    if (_lockHeld) {
      _lockHeld = false;
      await _lock.release();
    }
    try {
      await client.disconnect();
    } catch (e) {
      debugPrint('TV Saver: disconnect on close failed: $e');
    }
    await SystemNavigator.pop();
  }

  /// Whether the Connect screen is busy trying (spinner, no Retry).
  bool get busy =>
      hub.phase == HubConnectionPhase.connecting ||
      hub.phase == HubConnectionPhase.reconnecting;

  /// Whether the Connect screen offers Retry.
  bool get canRetry =>
      _hasPairing &&
      switch (hub.phase) {
        HubConnectionPhase.offline ||
        HubConnectionPhase.appNotOpen ||
        HubConnectionPhase.disconnected ||
        HubConnectionPhase.wrongTv => true,
        _ => false,
      };

  /// Loads the saved pairing and, when there is one, reconnects.
  Future<void> start() async {
    if (_starting) return;
    _starting = true;
    SavedHubPairing? saved;
    try {
      saved = await store.getLastPairing();
    } catch (_) {}
    if (_disposed) return;
    _hasPairing = saved != null;
    _started = true;
    notifyListeners();
    if (saved != null) {
      unawaited(_guarded(() async => client.reconnectSavedHub()));
    }
  }

  /// Runs a client call; an unexpected error becomes a visible state instead
  /// of escaping.
  Future<void> _guarded(Future<void> Function() body) async {
    try {
      await body();
    } catch (e) {
      debugPrint('TV Saver: a connection call failed: $e');
      if (_disposed) return;
      client.state.value = hub.copyWith(
        phase: HubConnectionPhase.disconnected,
        lastError: HubMessages.connectionLost,
      );
    }
  }

  /// The app went to the background or came back: the multicast lock must
  /// not be held while paused.
  void setForeground(bool value) {
    _foreground = value;
    if (value && _closing) {
      // The activity survived Close app: connect again to the saved Pi.
      _closing = false;
      unawaited(_guarded(() async => client.reconnectSavedHub()));
    }
    _syncLock();
  }

  /// Called by the scanner while it is on screen: mDNS may be needed.
  void setScanning(bool value) {
    _scanning = value;
    _syncLock();
  }

  /// Hands a scanned code to the client. Codes that are not TV Saver QR codes
  /// are rejected without touching the connection.
  Future<QrOutcome> pairFromQr(String raw) async {
    if (PairQrData.tryParse(raw) == null) return QrOutcome.invalid;
    unawaited(_connectQr(raw));
    return QrOutcome.started;
  }

  Future<void> _connectQr(String raw) async {
    await _guarded(() async {
      // Drop any attempt still in flight (a retry loop, an earlier scan).
      await client.disconnect();
      await client.connectFromQrUri(raw);
    });
    await _refreshPairing();
  }

  void submitPin(String pin) => client.submitPin(pin);

  /// Answers the pending TV: Approve sends `devices.approveDisplay`; Deny
  /// only dismisses it (the Pi lets the request time out).
  Future<void> answerApproval(bool approve) async {
    final a = _approval;
    _approval = null;
    if (!_disposed) notifyListeners();
    if (!approve || a == null) return;
    try {
      await client.request('devices.approveDisplay', {
        'requestId': a.requestId,
      });
    } on HubError catch (e) {
      _playerError = e.message ?? e.code;
      if (!_disposed) notifyListeners();
    } catch (_) {}
  }

  // ---- player ----

  /// Starts the one playlist there is until story 4-4: `all`.
  Future<void> play() => _player('player.play', {'playlistId': 'all'});
  Future<void> next() => _player('player.next');
  Future<void> prev() => _player('player.prev');

  /// Pause when playing, resume otherwise.
  Future<void> togglePause() =>
      _player(_nowPlaying.isPlaying ? 'player.pause' : 'player.resume');

  /// Seeks [deltaMs] from the position on screen now.
  Future<void> seekBy(int deltaMs) {
    final target = positionMs + deltaMs;
    return _player('player.seek', {'positionMs': target < 0 ? 0 : target});
  }

  Future<void> toggleMute() =>
      _player('player.setMuted', {'muted': !_nowPlaying.muted});

  Future<void> _player(
    String type, [
    Map<String, Object?> args = const {},
  ]) async {
    try {
      await client.request(type, args);
      _tvNotConnected = false;
      _playerError = null;
    } on HubError catch (e) {
      if (e.code == HubErrorCode.unavailable) {
        _tvNotConnected = true;
        _playerError = null;
      } else {
        _playerError = e.message ?? e.code;
      }
    } catch (_) {
      _playerError = HubMessages.connectionLost;
    }
    if (!_disposed) notifyListeners();
  }

  /// Leaves the PIN screen without pairing.
  Future<void> cancelPin() async {
    await client.disconnect();
    await _refreshPairing();
  }

  Future<void> retry() => _guarded(() async => client.retryNow());

  /// Removes only this phone's pairing: the Pi keeps the device record.
  /// Disconnects first so the client cannot save the token again. Returns
  /// false when the pairing could not be removed.
  Future<bool> forgetThisPi() async {
    var hubId = hub.hubId;
    if (hubId == null) {
      try {
        hubId = (await store.getLastPairing())?.hubId;
      } catch (_) {}
    }
    await _guarded(client.disconnect);
    var ok = true;
    try {
      if (hubId != null) await store.removePairing(hubId);
    } catch (_) {
      ok = false;
    }
    _clearRemote();
    await _refreshPairing();
    return ok;
  }

  Future<void> _refreshPairing() async {
    try {
      _hasPairing = await store.getLastPairing() != null;
    } catch (_) {}
    if (!_disposed) notifyListeners();
  }

  void _onHubState() {
    final phase = hub.phase;
    if (phase == HubConnectionPhase.connected) {
      _hasPairing = true;
      _wasConnected = true;
    } else if (phase != HubConnectionPhase.connecting &&
        phase != HubConnectionPhase.reconnecting &&
        phase != HubConnectionPhase.offline &&
        phase != HubConnectionPhase.appNotOpen) {
      _wasConnected = false;
      _clearRemote();
    }
    if (phase != HubConnectionPhase.connected) {
      // Keep the last list while the link comes back.
      if (!_wasConnected) _devices = const [];
      if (!hub.knownPairing && hub.phase != HubConnectionPhase.connecting) {
        unawaited(_refreshPairing());
      }
    }
    _syncLock();
    if (!_disposed) notifyListeners();
  }

  void _syncLock() {
    final phase = hub.phase;
    final want =
        _foreground &&
        !_closing &&
        (_scanning ||
            phase == HubConnectionPhase.connecting ||
            phase == HubConnectionPhase.reconnecting ||
            phase == HubConnectionPhase.offline ||
            phase == HubConnectionPhase.appNotOpen);
    if (want == _lockHeld) return;
    _lockHeld = want;
    unawaited(want ? _lock.acquire() : _lock.release());
  }

  void _onSnapshot(Map<String, dynamic> snap) {
    final modules = snap['modules'];
    final devices = modules is Map ? modules['devices'] : null;
    _setDevices(devices is Map ? devices['devices'] : null);
    final player = NowPlaying.tryParse(
      modules is Map ? modules['player'] : null,
    );
    if (player != null) _nowPlaying = player;
    final display = modules is Map ? modules['display'] : null;
    if (display is Map && display['online'] is bool) {
      _setDisplayOnline(display['online'] as bool);
    }
    _readSettings(modules is Map ? modules['settings'] : null);
    _readLibrary(modules is Map ? modules['library'] : null);
    if (!_disposed) notifyListeners();
  }

  void _onEvent(Map<String, dynamic> ev) {
    if (ev['t'] == 'devices.approvalRequested') {
      final id = ev['requestId'];
      if (id is String && id.isNotEmpty) {
        _approval = PendingApproval(id, '${ev['name'] ?? 'TV'}');
        if (!_disposed) notifyListeners();
      }
      return;
    }
    if (ev['t'] == 'devices.approvalCancelled') {
      if (_approval?.requestId == ev['requestId']) {
        _approval = null;
        if (!_disposed) notifyListeners();
      }
      return;
    }
    final data = ev['data'];
    switch (ev['kind']) {
      case 'devices.changed':
        _setDevices(data is Map ? data['devices'] : null);
      case 'player.changed':
        final player = NowPlaying.tryParse(data);
        if (player == null) return;
        _nowPlaying = player;
        if (!_disposed) notifyListeners();
      case 'settings.changed':
        final values = data is Map ? data['values'] : null;
        if (values is Map) {
          _settings = {..._settings, ...Map<String, Object?>.from(values)};
          if (!_disposed) notifyListeners();
        }
      case 'library.added':
      case 'library.updated':
        _noteItem(data);
        _readStorage(data);
        if (!_disposed) notifyListeners();
      case 'library.removed':
        final id = data is Map ? data['id'] : null;
        if (id is String) {
          _itemNames.remove(id);
          _itemDurations.remove(id);
          _items.remove(id);
        }
        _readStorage(data);
        if (!_disposed) notifyListeners();
      case 'library.storage':
        _readStorage(data);
        if (!_disposed) notifyListeners();
      case 'display.changed':
        if (data is Map && data['online'] is bool) {
          _setDisplayOnline(data['online'] as bool);
          if (!_disposed) notifyListeners();
        }
    }
  }

  /// A snapshot without a `settings` module clears what an older one said.
  void _readSettings(Object? raw) {
    if (raw is! Map) {
      _settings = const {};
      _limits = const {};
      return;
    }
    final values = raw['values'];
    _settings = values is Map ? Map<String, Object?>.from(values) : const {};
    final limits = raw['limits'];
    _limits = limits is Map
        ? {
            for (final e in limits.entries)
              if (e.value is Map &&
                  e.value['min'] is int &&
                  e.value['max'] is int)
                '${e.key}': {
                  'min': e.value['min'] as int,
                  'max': e.value['max'] as int,
                },
          }
        : const {};
  }

  void _readLibrary(Object? raw) {
    _itemNames.clear();
    _itemDurations.clear();
    _items.clear();
    _usedBytes = 0;
    _capBytes = 0;
    _hasLibrary = false;
    if (raw is! Map) return;
    final items = raw['items'];
    if (items is List) {
      for (final i in items) {
        _noteItem(i);
      }
    }
    _readStorage(raw);
    _hasLibrary = true;
  }

  /// The Pi's own `storage {usedBytes, capBytes}` figure, in a snapshot or an
  /// event.
  void _readStorage(Object? raw) {
    final storage = raw is Map ? raw['storage'] : null;
    if (storage is! Map) return;
    final used = storage['usedBytes'];
    final cap = storage['capBytes'];
    if (used is int) _usedBytes = used;
    if (cap is int) _capBytes = cap;
  }

  void _noteItem(Object? raw) {
    if (raw is! Map) return;
    final id = raw['id'];
    if (id is! String) return;
    _items[id] = Map<String, Object?>.from(raw);
    final name = raw['name'];
    if (name is String && name.isNotEmpty) _itemNames[id] = name;
    final duration = raw['durationMs'];
    if (duration is int && duration > 0) {
      _itemDurations[id] = duration;
    } else {
      _itemDurations.remove(id);
    }
  }

  /// Forget everything the Pi told this phone (the pairing is gone).
  void _clearRemote() {
    _readSettings(null);
    _readLibrary(null);
    _devices = const [];
  }

  void _setDisplayOnline(bool online) {
    _displayOnline = online;
    if (online) _tvNotConnected = false;
  }

  void _setDevices(Object? list) {
    if (list is! List) return;
    final parsed = <DeviceInfo>[];
    for (final d in list) {
      try {
        if (d is Map<String, dynamic>) parsed.add(DeviceInfo.fromJson(d));
      } catch (_) {
        // Skip a malformed entry, keep the rest.
      }
    }
    _devices = parsed;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    client.state.removeListener(_onHubState);
    for (final s in _subs) {
      s.cancel();
    }
    _uploader?.dispose();
    if (_lockHeld) {
      _lockHeld = false;
      unawaited(_lock.release());
    }
    super.dispose();
  }
}
