import 'dart:async';

import 'package:hub_core/hub_core.dart';
import 'package:tv_saver/shared/multicast_lock.dart';
import 'package:tv_saver/phone/phone_controller.dart';

/// Records lock calls instead of talking to Android.
class FakeLock extends MulticastLock {
  int acquired = 0;
  int released = 0;

  int get held => acquired - released;

  @override
  Future<void> acquire() async => acquired++;

  @override
  Future<void> release() async => released++;
}

/// mDNS stand-in: emits [endpoints] once per scan, no multicast.
class FakeScanner extends HubScanner {
  FakeScanner([this.endpoints = const []]);

  List<HubEndpoint> endpoints;
  int scans = 0;

  @override
  Stream<HubEndpoint> scan() {
    scans++;
    return Stream.fromIterable(endpoints);
  }
}

Future<void> until(
  bool Function() cond, {
  Duration timeout = const Duration(seconds: 8),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!cond()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Condition not met in $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Future<void> untilAsync(
  Future<bool> Function() cond, {
  Duration timeout = const Duration(seconds: 8),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!await cond()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Condition not met in $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

/// A real in-process hub (in-memory database, loopback socket).
class Rig {
  Rig._(this.db, this.server, this.display, this.player, this.settings);

  final HubDatabase db;
  final HubServer server;

  /// Set when the rig was started with `withSettings`.
  final SettingsStore? settings;

  /// Set when the rig was started with `playlists`.
  final DisplayModule? display;
  final PlayerModule? player;

  static Future<Rig> start({
    int port = 0,
    String? dbFile,
    PlaylistSource? playlists,
    bool withSettings = false,
  }) async {
    final db = dbFile == null
        ? HubDatabase.inMemory()
        : HubDatabase.open(dbFile);
    final server = HubServer(
      db: db,
      store: MemoryTvStore('hub-phone-test'),
      name: 'Test Pi',
      preferredPort: port,
    );
    server.registerModule(
      DevicesModule(
        db: db,
        onForgetDevice: server.forgetDevice,
        onStartPairing: server.startPairingFor,
        onCancelPairing: server.cancelPairingFor,
        onApproveDisplay: server.approveDisplay,
        onForgetAllPhones: server.forgetAllPhones,
      ),
    );
    DisplayModule? display;
    PlayerModule? player;
    if (playlists != null) {
      display = DisplayModule(db: db);
      player = PlayerModule(db: db, display: display, playlists: playlists);
      server.registerModule(display);
      server.registerModule(player);
    }
    SettingsStore? settings;
    if (withSettings) {
      settings = SettingsStore(
        db: db,
        config: ServerConfig(mediaDir: 'unused', tokenFile: 'unused'),
      );
      await settings.load();
      server.registerModule(SettingsModule(settings));
    }
    await server.start();
    return Rig._(db, server, display, player, settings);
  }

  /// Opens a pairing session and returns its QR URI.
  String openQr() {
    server.openPairingSession();
    return server.currentQrUri('127.0.0.1')!;
  }

  Future<void> dispose() async {
    await server.stop();
    await db.close();
  }
}

/// One phone: client, store and controller wired like `main_phone.dart`.
class PhoneRig {
  PhoneRig({
    HubTokenStore? store,
    HubScanner? scanner,
    FakeLock? lock,
    Duration directTimeout = const Duration(milliseconds: 400),
    Duration mdnsTimeout = const Duration(milliseconds: 400),
  }) : store = store ?? MemoryHubTokenStore(),
       lock = lock ?? FakeLock() {
    client = HubClient(
      tokenStore: this.store,
      clientName: 'Test phone',
      scanner: scanner ?? FakeScanner(),
      directTimeout: directTimeout,
      mdnsTimeout: mdnsTimeout,
    );
    controller = PhoneController(
      client: client,
      store: this.store,
      lock: this.lock,
    );
  }

  final HubTokenStore store;
  final FakeLock lock;
  late final HubClient client;
  late final PhoneController controller;

  Future<void> waitFor(PhoneScreen screen) =>
      until(() => controller.screen == screen);

  bool _disposed = false;

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    controller.dispose();
    await client.dispose();
  }
}
