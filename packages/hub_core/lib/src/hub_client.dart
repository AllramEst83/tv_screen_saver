import 'dart:async';
import 'dart:io';

import 'server/hub_module.dart';
import 'clock_offset.dart';
import 'hub_scanner.dart';
import 'observable.dart';
import 'protocol.dart';
import 'token_store.dart';

/// User-facing messages for connection problems.
abstract final class HubMessages {
  static const appNotOpen =
      "TV Saver isn't open on the TV. Open it with the remote.";
  static const tvNotFound = 'TV not found';
  static const wrongTv = 'A different TV answered at that address.';
  static const invalidQr = "That isn't a TV Saver QR code.";
  static const wrongPin = 'Wrong PIN or expired code.';
  static const replaced = 'This phone was connected from somewhere else.';
  static const tvFull = 'This TV already has the maximum number of phones.';
  static const upgradeTv =
      'The TV app is older than this app. On the TV, open the drawer and '
      'choose "Check for updates".';
  static const revoked = 'This TV no longer knows this phone. Pair again.';
  static const notConnected = 'Not connected to the TV';
  static const connectionLost = 'The connection was lost';

  static String tooManyTries(int retryInMs) =>
      'Too many tries. Wait ${(retryInMs / 1000).ceil()} s.';
}

enum HubConnectionPhase {
  disconnected,
  connecting,
  awaitingPin,
  connected,
  reconnecting,
  replaced,

  /// The TV did not answer in time ("TV not found").
  offline,

  /// The TV refused the TCP connection: the app is closed on the TV.
  appNotOpen,

  /// Another TV answered with a different hub id.
  wrongTv,

  /// The phone speaks a newer protocol than the TV.
  needsTvUpdate,
}

class HubClientState {
  const HubClientState({
    this.phase = HubConnectionPhase.disconnected,
    this.hubId,
    this.hubName,
    this.host,
    this.port,
    this.device,
    this.lastError,
    this.pinRetryInMs,
    this.knownPairing = false,
  });

  final HubConnectionPhase phase;
  final String? hubId;
  final String? hubName;
  final String? host;
  final int? port;
  final DeviceInfo? device;
  final String? lastError;
  final int? pinRetryInMs;

  /// True when this phone holds a token for the TV it is (re)connecting to.
  final bool knownPairing;

  HubClientState copyWith({
    HubConnectionPhase? phase,
    String? hubId,
    String? hubName,
    String? host,
    int? port,
    DeviceInfo? device,
    String? lastError,
    bool clearError = false,
    int? pinRetryInMs,
    bool clearPinRetry = false,
    bool? knownPairing,
  }) => HubClientState(
    phase: phase ?? this.phase,
    hubId: hubId ?? this.hubId,
    hubName: hubName ?? this.hubName,
    host: host ?? this.host,
    port: port ?? this.port,
    device: device ?? this.device,
    lastError: clearError ? null : (lastError ?? this.lastError),
    pinRetryInMs: clearPinRetry ? null : (pinRetryInMs ?? this.pinRetryInMs),
    knownPairing: knownPairing ?? this.knownPairing,
  );
}

/// Whether [e] means the remote host actively refused the TCP connection
/// (nothing listens on the port), as opposed to a timeout.
bool isConnectionRefused(Object e) {
  if (e is! SocketException) return false;
  final code = e.osError?.errorCode;
  // ECONNREFUSED: 111 Linux/Android, 61 macOS/iOS, 10061 and 1225 Windows.
  return code == 111 || code == 61 || code == 10061 || code == 1225;
}

enum _Open { ok, refused, failed }

/// Phone-side Hub Protocol v1 WebSocket client.
///
/// Handles QR one-step pairing, mDNS plus 4-digit PIN pairing, rtt-based clock
/// offset, correlated `rid` requests, snapshot resync on `rev` gap, and
/// automatic reconnection: last address (2.5 s), then mDNS (about 6 s), then
/// retries with backoff 1, 2, 3, 5, 8 s.
class HubClient {
  HubClient({
    required this.tokenStore,
    required this.clientName,
    HubScanner? scanner,
    DateTime Function()? now,
    this.directTimeout = const Duration(milliseconds: 2500),
    this.mdnsTimeout = const Duration(seconds: 6),
    this.pingInterval = const Duration(seconds: 5),
    this.deadAfter = const Duration(seconds: 15),
    this.reconnectBackoff = const [
      Duration(seconds: 1),
      Duration(seconds: 2),
      Duration(seconds: 3),
      Duration(seconds: 5),
      Duration(seconds: 8),
    ],
  }) : _scanner = scanner ?? HubScanner(timeout: const Duration(seconds: 6)),
       _now = now ?? DateTime.now;

  final HubTokenStore tokenStore;
  final String clientName;
  final HubScanner _scanner;
  final DateTime Function() _now;
  final Duration directTimeout;
  final Duration mdnsTimeout;
  final Duration pingInterval;

  /// No frame for this long means the TV vanished without closing the socket.
  final Duration deadAfter;
  final List<Duration> reconnectBackoff;

  final Observable<HubClientState> state = Observable(const HubClientState());

  final _framesCtrl = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get frames => _framesCtrl.stream;

  final _snapshotCtrl = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get snapshots => _snapshotCtrl.stream;

  final _eventsCtrl = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get events => _eventsCtrl.stream;

  Map<String, dynamic>? _lastSnapshot;
  Map<String, dynamic>? get lastSnapshot => _lastSnapshot;

  WebSocket? _socket;
  StreamSubscription<dynamic>? _socketSub;
  Timer? _pingTimer;
  Timer? _reconnectTimer;

  int _ridSeq = 0;
  final Map<int, Completer<Map<String, dynamic>>> _pending = {};
  int _lastRev = -1;
  final ClockOffsetEstimator _clock = ClockOffsetEstimator();
  String? _pendingToken;
  String? _expectedHubId;
  bool _manualDisconnect = false;

  /// Set when the TV answered with something final (PIN needed, wrong TV,
  /// upgrade needed, full, replaced): reconnect loops must stop.
  bool _terminal = false;
  int _reconnectAttempt = 0;
  int _generation = 0;
  bool _sentToken = false;
  late DateTime _lastFrameAt = _now();

  /// Estimated TV epoch milliseconds, compensating for phone/TV clock skew.
  int get estimatedTvNowMs => _now().millisecondsSinceEpoch + _clock.offsetMs;

  /// The TV's epoch milliseconds now: the phone clock plus the offset of the
  /// lowest-rtt pong sample. Timers show `endsAt - tvNowMs()`.
  int tvNowMs() => estimatedTvNowMs;

  /// Seeds the clock offset from a TV `now` that arrived without a round
  /// trip (a `timer.changed` event). One-way, so it only stands in until a
  /// pong sample exists; the lowest-rtt sample then replaces it.
  void noteTvNow(Object? tvNow) {
    if (tvNow is num && tvNow.isFinite && !_clock.hasSamples) {
      _clock.setProvisional(tvNow.toInt(), _now().millisecondsSinceEpoch);
    }
  }

  int get clockOffsetMs => _clock.offsetMs;
  int get lastRev => _lastRev;

  /// Connects using a scanned `tvsaver://pair?...` QR code (one-step pairing).
  /// Completes when the handshake settles; returns true when connected.
  Future<bool> connectFromQrUri(String rawUri) async {
    final parsed = PairQrData.tryParse(rawUri);
    if (parsed == null) {
      state.value = state.value.copyWith(
        phase: HubConnectionPhase.disconnected,
        lastError: HubMessages.invalidQr,
      );
      return false;
    }
    SavedHubPairing? saved;
    try {
      saved = await tokenStore.getPairing(parsed.hubId);
    } catch (_) {}
    return _connectUser(
      host: parsed.host,
      port: parsed.port,
      hubName: saved?.hubName ?? 'TV Saver',
      expectedHubId: parsed.hubId,
      token: saved?.token,
      pairCode: parsed.pairCode,
    );
  }

  /// Connects to a discovered mDNS [endpoint] or a manually entered address.
  Future<bool> connectEndpoint(HubEndpoint endpoint) async {
    SavedHubPairing? saved;
    if (endpoint.id != null) {
      try {
        saved = await tokenStore.getPairing(endpoint.id!);
      } catch (_) {}
    }
    return _connectUser(
      host: endpoint.host,
      port: endpoint.port,
      hubName: endpoint.name,
      expectedHubId: endpoint.id,
      token: saved?.token,
    );
  }

  Future<bool> _connectUser({
    required String host,
    required int port,
    required String hubName,
    String? expectedHubId,
    String? token,
    String? pairCode,
  }) async {
    final gen = ++_generation;
    _reconnectTimer?.cancel();
    _reconnectAttempt = 0;
    final outcome = await _openSocket(
      host: host,
      port: port,
      hubName: hubName,
      expectedHubId: expectedHubId,
      token: token,
      pairCode: pairCode,
      timeout: const Duration(seconds: 5),
      gen: gen,
    );
    if (gen != _generation) return false;
    if (outcome != _Open.ok) {
      _setOpenFailure(outcome);
      return false;
    }
    final ok = await _awaitHandshake(const Duration(seconds: 5), gen);
    if (!ok &&
        gen == _generation &&
        !_terminal &&
        state.value.phase == HubConnectionPhase.connecting) {
      _setOpenFailure(_Open.failed);
    }
    return ok;
  }

  /// Reconnects to the last paired TV: last address, then mDNS, then offline.
  /// On failure it keeps retrying with backoff until connected, told to stop
  /// by the TV (PIN needed, replaced, ...) or [disconnect] is called.
  Future<bool> reconnectSavedHub() async {
    SavedHubPairing? saved;
    try {
      saved = await tokenStore.getLastPairing();
    } catch (_) {}
    if (saved == null) return false;
    final gen = ++_generation;
    _manualDisconnect = false;
    _reconnectTimer?.cancel();
    state.value = state.value.copyWith(
      phase: HubConnectionPhase.reconnecting,
      hubId: saved.hubId,
      hubName: saved.hubName,
      host: saved.lastHost,
      port: saved.lastPort,
      knownPairing: true,
      clearError: true,
    );

    var refused = false;

    // Step 1: last known address, verified by hub id.
    if (saved.lastHost.isNotEmpty) {
      final outcome = await _tryHub(
        host: saved.lastHost,
        port: saved.lastPort,
        hubName: saved.hubName,
        saved: saved,
        timeout: directTimeout,
        gen: gen,
      );
      if (gen != _generation) return false;
      if (outcome == null) return true;
      if (_terminal) return false;
      if (outcome == _Open.refused) {
        refused = true;
        state.value = state.value.copyWith(
          phase: HubConnectionPhase.appNotOpen,
          lastError: HubMessages.appNotOpen,
        );
      }
    }

    // Step 2: mDNS scan for the hub id (survives a new DHCP address).
    try {
      await for (final ep in _scanner.scan().timeout(mdnsTimeout)) {
        if (gen != _generation) return false;
        if (ep.id != saved.hubId) continue;
        final outcome = await _tryHub(
          host: ep.host,
          port: ep.port,
          hubName: ep.name,
          saved: saved,
          timeout: const Duration(seconds: 3),
          gen: gen,
        );
        if (gen != _generation) return false;
        if (outcome == null) return true;
        if (_terminal) return false;
        if (outcome == _Open.refused) refused = true;
      }
    } catch (_) {
      // Multicast unavailable or scan timed out: fall through.
    }
    if (gen != _generation) return false;

    state.value = refused
        ? state.value.copyWith(
            phase: HubConnectionPhase.appNotOpen,
            lastError: HubMessages.appNotOpen,
          )
        : state.value.copyWith(
            phase: HubConnectionPhase.offline,
            lastError: HubMessages.tvNotFound,
          );
    if (!_manualDisconnect) _scheduleRetry();
    return false;
  }

  /// Tries one address. Returns `null` when connected, otherwise how the
  /// attempt failed.
  Future<_Open?> _tryHub({
    required String host,
    required int port,
    required String hubName,
    required SavedHubPairing saved,
    required Duration timeout,
    required int gen,
  }) async {
    final elapsed = Stopwatch()..start();
    final outcome = await _openSocket(
      host: host,
      port: port,
      hubName: hubName,
      expectedHubId: saved.hubId,
      token: saved.token,
      timeout: timeout,
      gen: gen,
    );
    if (gen != _generation) return _Open.failed;
    if (outcome != _Open.ok) return outcome;
    var remaining = timeout - elapsed.elapsed;
    if (remaining < const Duration(milliseconds: 100)) {
      remaining = const Duration(milliseconds: 100);
    }
    final connected = await _awaitHandshake(remaining, gen);
    return connected ? null : _Open.failed;
  }

  void _scheduleRetry() {
    _reconnectTimer?.cancel();
    final idx = _reconnectAttempt.clamp(0, reconnectBackoff.length - 1);
    _reconnectAttempt++;
    _reconnectTimer = Timer(reconnectBackoff[idx], () {
      if (_manualDisconnect || _terminal) return;
      unawaited(reconnectSavedHub());
    });
  }

  /// Makes the stored pairing [hubId] the active TV and connects to it.
  Future<bool> switchToSaved(String hubId) async {
    SavedHubPairing? saved;
    try {
      saved = await tokenStore.getPairing(hubId);
    } catch (_) {}
    if (saved == null) return false;
    await tokenStore.setActive(hubId);
    await disconnect();
    return reconnectSavedHub();
  }

  /// Immediately retries the saved TV (the "Try again" button).
  Future<bool> retryNow() async {
    _reconnectAttempt = 0;
    return reconnectSavedHub();
  }

  /// Submits a 4-digit PIN when in [HubConnectionPhase.awaitingPin].
  void submitPin(String pin) {
    state.value = state.value.copyWith(clearError: true, clearPinRetry: true);
    sendFireAndForget(HubMsg.pair, {'pin': pin.trim()});
  }

  /// Sends a correlated request with an auto-incrementing `rid`; awaits `ok`
  /// or throws [HubError].
  Future<Map<String, dynamic>> request(
    String type, [
    Map<String, Object?> args = const {},
    Duration timeout = const Duration(seconds: 6),
  ]) async {
    final ws = _socket;
    if (ws == null || ws.readyState != WebSocket.open) {
      throw const HubError(HubErrorCode.unauthorized, HubMessages.notConnected);
    }
    final rid = ++_ridSeq;
    final completer = Completer<Map<String, dynamic>>();
    _pending[rid] = completer;
    ws.add(encodeFrame(type, {'rid': rid, ...args}));
    try {
      return await completer.future.timeout(timeout);
    } finally {
      _pending.remove(rid);
    }
  }

  /// Sends a frame without awaiting a response (hot frames, pings).
  void sendFireAndForget(
    String type, [
    Map<String, Object?> fields = const {},
  ]) {
    final ws = _socket;
    if (ws != null && ws.readyState == WebSocket.open) {
      ws.add(encodeFrame(type, fields));
    }
  }

  HttpClient? _http;

  /// Opens an HTTP request to the connected TV with the saved token in the
  /// `Authorization` header (never in the URL). The caller writes the body and
  /// closes the request.
  Future<HttpClientRequest> openAuthorized(
    String method,
    String path, {
    Map<String, String> headers = const {},
  }) async {
    final st = state.value;
    final host = st.host;
    final port = st.port;
    final hubId = st.hubId;
    if (host == null || port == null || hubId == null) {
      throw const HubError(HubErrorCode.unauthorized, HubMessages.notConnected);
    }
    SavedHubPairing? saved;
    try {
      saved = await tokenStore.getPairing(hubId);
    } catch (_) {}
    final token = saved?.token;
    if (token == null || token.isEmpty) {
      throw const HubError(HubErrorCode.unauthorized, HubMessages.notConnected);
    }
    final http = _http ??= HttpClient()
      ..connectionTimeout = const Duration(seconds: 5);
    final req = await http.openUrl(
      method,
      Uri(scheme: 'http', host: host, port: port, path: path),
    );
    req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    headers.forEach(req.headers.set);
    return req;
  }

  Future<void> disconnect() async {
    _manualDisconnect = true;
    _generation++;
    _reconnectTimer?.cancel();
    await _closeSocket();
    state.value = const HubClientState(phase: HubConnectionPhase.disconnected);
  }

  Future<void> dispose() async {
    await disconnect();
    _http?.close(force: true);
    _http = null;
    await _framesCtrl.close();
    await _snapshotCtrl.close();
    await _eventsCtrl.close();
    state.dispose();
  }

  // ---- Internal socket lifecycle ----

  void _setOpenFailure(_Open outcome) {
    state.value = outcome == _Open.refused
        ? state.value.copyWith(
            phase: HubConnectionPhase.appNotOpen,
            lastError: HubMessages.appNotOpen,
          )
        : state.value.copyWith(
            phase: HubConnectionPhase.offline,
            lastError: HubMessages.tvNotFound,
          );
  }

  Future<_Open> _openSocket({
    required String host,
    required int port,
    required String hubName,
    String? expectedHubId,
    String? token,
    String? pairCode,
    Duration timeout = const Duration(seconds: 5),
    required int gen,
  }) async {
    _manualDisconnect = false;
    await _closeSocket();

    _terminal = false;
    _expectedHubId = expectedHubId;
    _pendingToken = token;
    _sentToken = token != null && token.isNotEmpty;
    _lastRev = -1;
    _clock.reset();

    // While reconnecting to a known TV the UI keeps its banner: no flip to
    // `connecting`.
    final keep =
        state.value.knownPairing &&
        (state.value.phase == HubConnectionPhase.reconnecting ||
            state.value.phase == HubConnectionPhase.appNotOpen ||
            state.value.phase == HubConnectionPhase.offline);
    state.value = state.value.copyWith(
      phase: keep ? state.value.phase : HubConnectionPhase.connecting,
      host: host,
      port: port,
      hubName: hubName,
      hubId: expectedHubId ?? state.value.hubId,
      clearError: !keep,
      clearPinRetry: true,
    );

    Future<WebSocket>? connecting;
    try {
      connecting = WebSocket.connect(
        Uri(scheme: 'ws', host: host, port: port, path: kWsPath).toString(),
      );
      final ws = await connecting.timeout(timeout);
      if (gen != _generation) {
        unawaited(ws.close());
        return _Open.failed;
      }
      _lastFrameAt = _now();
      _socket = ws;
      _socketSub = ws.listen(
        _onRawFrame,
        onDone: _onSocketClosed,
        onError: (_) => _onSocketClosed(),
        cancelOnError: true,
      );
      ws.add(
        encodeFrame(HubMsg.hello, {
          'v': kProtocolVersion,
          'client': clientName,
          if (token != null && token.isNotEmpty) 'token': token,
          if (pairCode != null && pairCode.isNotEmpty) 'pairCode': pairCode,
        }),
      );
      return _Open.ok;
    } on TimeoutException {
      // A late success must not leak a socket.
      unawaited(
        connecting!.then<void>((ws) => ws.close(), onError: (Object _) {}),
      );
      return _Open.failed;
    } catch (e) {
      return isConnectionRefused(e) ? _Open.refused : _Open.failed;
    }
  }

  /// Waits for the handshake after the socket opened. Returns true on
  /// `ready`; false on a final answer (PIN needed, wrong TV, ...) or timeout.
  Future<bool> _awaitHandshake(Duration timeout, int gen) async {
    final done = Completer<bool>();
    void check() {
      if (done.isCompleted) return;
      if (gen != _generation) {
        done.complete(false);
      } else if (state.value.phase == HubConnectionPhase.connected) {
        done.complete(true);
      } else if (_terminal) {
        done.complete(false);
      }
    }

    final poll = Timer.periodic(
      const Duration(milliseconds: 20),
      (_) => check(),
    );
    state.addListener(check);
    check();
    final result = await done.future.timeout(timeout, onTimeout: () => false);
    poll.cancel();
    state.removeListener(check);
    if (done.isCompleted && result) return true;
    if (gen != _generation || _terminal) return false;
    if (state.value.phase == HubConnectionPhase.connected) return true;
    if (gen == _generation && !_terminal) await _closeSocket();
    return false;
  }

  Future<void> _closeSocket() async {
    _pingTimer?.cancel();
    _pingTimer = null;
    await _socketSub?.cancel();
    _socketSub = null;
    final ws = _socket;
    _socket = null;
    if (ws != null) {
      try {
        await ws.close();
      } catch (_) {}
    }
    for (final c in _pending.values) {
      if (!c.isCompleted) {
        c.completeError(
          const HubError(HubErrorCode.unauthorized, HubMessages.connectionLost),
        );
      }
    }
    _pending.clear();
  }

  void _onRawFrame(dynamic raw) {
    _lastFrameAt = _now();
    final msg = decodeFrame(raw);
    if (msg == null) return;
    if (!_framesCtrl.isClosed) _framesCtrl.add(msg);
    final t = msg['t'] as String;

    switch (t) {
      case HubMsg.pairRequired:
        _terminal = true;
        if (_sentToken) {
          // The TV does not know our token any more: drop it, pair again.
          _sentToken = false;
          _pendingToken = null;
          final hubId = _expectedHubId ?? state.value.hubId;
          if (hubId != null) {
            unawaited(() async {
              try {
                await tokenStore.removePairing(hubId);
              } catch (_) {}
            }());
          }
          state.value = state.value.copyWith(
            phase: HubConnectionPhase.awaitingPin,
            knownPairing: false,
            lastError: HubMessages.revoked,
          );
        } else {
          state.value = state.value.copyWith(
            phase: HubConnectionPhase.awaitingPin,
            clearError: true,
          );
        }

      case HubMsg.pairFailed:
        final retryMs = (msg['retryInMs'] as num?)?.toInt();
        state.value = state.value.copyWith(
          phase: HubConnectionPhase.awaitingPin,
          pinRetryInMs: retryMs,
          lastError: retryMs != null
              ? HubMessages.tooManyTries(retryMs)
              : HubMessages.wrongPin,
        );

      case HubMsg.paired:
        final tok = msg['token'] as String?;
        if (tok != null && tok.isNotEmpty) {
          _pendingToken = tok;
        }

      case HubMsg.ready:
        _onReady(msg);

      case HubMsg.snapshot:
        _lastRev = (msg['rev'] as num?)?.toInt() ?? _lastRev;
        _provisionalClock(msg);
        _lastSnapshot = msg;
        if (!_snapshotCtrl.isClosed) _snapshotCtrl.add(msg);

      case HubMsg.event:
        final evRev = (msg['rev'] as num?)?.toInt();
        if (evRev != null && _lastRev >= 0 && evRev != _lastRev + 1) {
          // Gap detected: ask the TV for a full snapshot.
          sendFireAndForget(HubMsg.sync, {'sinceRev': _lastRev});
        }
        if (evRev != null) _lastRev = evRev;
        if (!_eventsCtrl.isClosed) _eventsCtrl.add(msg);

      case HubMsg.pong:
        final tvNow = (msg['now'] as num?)?.toInt();
        final ts = (msg['ts'] as num?)?.toInt();
        if (tvNow != null && ts != null) {
          _clock.addSample(
            sentTs: ts,
            receivedAt: _now().millisecondsSinceEpoch,
            tvNow: tvNow,
          );
        }

      case HubMsg.ok:
        final rid = (msg['rid'] as num?)?.toInt();
        final completer = rid == null ? null : _pending.remove(rid);
        if (completer != null && !completer.isCompleted) {
          final res = msg['result'];
          completer.complete(
            res is Map<String, dynamic> ? res : <String, dynamic>{'value': res},
          );
        }

      case HubMsg.err:
        _onErr(msg);

      case HubMsg.replaced:
        _terminal = true;
        _manualDisconnect = true;
        _reconnectTimer?.cancel();
        state.value = state.value.copyWith(
          phase: HubConnectionPhase.replaced,
          lastError: HubMessages.replaced,
        );
        _closeSocket();

      default:
        // Targeted or hot frames from modules.
        if (!_eventsCtrl.isClosed) _eventsCtrl.add(msg);
    }
  }

  void _provisionalClock(Map<String, dynamic> msg) {
    final tvNow = (msg['now'] as num?)?.toInt();
    if (tvNow != null) {
      _clock.setProvisional(tvNow, _now().millisecondsSinceEpoch);
    }
  }

  void _onReady(Map<String, dynamic> msg) {
    final serverId = msg['id'] as String? ?? '';
    final serverName =
        msg['name'] as String? ?? state.value.hubName ?? 'TV Saver';
    final expected = _expectedHubId;
    if (expected != null && expected.isNotEmpty && serverId != expected) {
      _terminal = true;
      state.value = state.value.copyWith(
        phase: HubConnectionPhase.wrongTv,
        lastError: HubMessages.wrongTv,
      );
      _closeSocket();
      return;
    }
    _provisionalClock(msg);
    final deviceJson = msg['device'];
    final device = deviceJson is Map<String, dynamic>
        ? DeviceInfo.fromJson(deviceJson).copyWith(online: true)
        : null;
    _reconnectAttempt = 0;

    // Persist the token and last known address keyed by the hub id.
    final tok = _pendingToken;
    if (tok != null && tok.isNotEmpty && serverId.isNotEmpty) {
      final record = SavedHubPairing(
        hubId: serverId,
        token: tok,
        lastHost: state.value.host ?? '',
        lastPort: state.value.port ?? kDefaultHubPort,
        hubName: serverName,
      );
      unawaited(() async {
        try {
          await tokenStore.savePairing(record);
        } catch (_) {}
      }());
    }

    state.value = state.value.copyWith(
      phase: HubConnectionPhase.connected,
      hubId: serverId,
      hubName: serverName,
      device: device,
      knownPairing: true,
      clearError: true,
    );
    _startHeartbeat();
  }

  void _onErr(Map<String, dynamic> msg) {
    final rid = (msg['rid'] as num?)?.toInt();
    final code = msg['code'] as String? ?? HubErrorCode.invalid;
    final errMsg = msg['msg'] as String?;
    final extra = Map<String, Object?>.from(msg)
      ..remove('t')
      ..remove('rid')
      ..remove('code')
      ..remove('msg');
    final completer = rid == null ? null : _pending.remove(rid);
    if (completer != null && !completer.isCompleted) {
      completer.completeError(HubError(code, errMsg, extra));
    } else if (code == HubErrorCode.upgradeTv) {
      _terminal = true;
      state.value = state.value.copyWith(
        phase: HubConnectionPhase.needsTvUpdate,
        lastError: HubMessages.upgradeTv,
      );
    } else if (code == HubErrorCode.conflict) {
      _terminal = true;
      state.value = state.value.copyWith(
        phase: HubConnectionPhase.disconnected,
        lastError: HubMessages.tvFull,
      );
    }
  }

  void _startHeartbeat() {
    _pingTimer?.cancel();
    void ping() =>
        sendFireAndForget(HubMsg.ping, {'ts': _now().millisecondsSinceEpoch});
    ping(); // An early sample gives a good clock offset right away.
    _lastFrameAt = _now();
    _pingTimer = Timer.periodic(pingInterval, (_) {
      if (_now().difference(_lastFrameAt) > deadAfter) {
        // The TV vanished without closing the socket: treat it as closed.
        _onSocketClosed();
        unawaited(_closeSocket());
        return;
      }
      ping();
    });
  }

  void _onSocketClosed() {
    _pingTimer?.cancel();
    _pingTimer = null;
    if (_manualDisconnect || state.value.phase == HubConnectionPhase.replaced) {
      return;
    }
    if (state.value.phase == HubConnectionPhase.awaitingPin) {
      state.value = state.value.copyWith(
        phase: HubConnectionPhase.disconnected,
        lastError: HubMessages.connectionLost,
      );
      return;
    }
    final phase = state.value.phase;
    if (phase == HubConnectionPhase.offline ||
        phase == HubConnectionPhase.appNotOpen ||
        phase == HubConnectionPhase.reconnecting) {
      // Closed mid-handshake while retrying: try again later.
      if (!_terminal) _scheduleRetry();
      return;
    }
    if (phase != HubConnectionPhase.connected) return;
    state.value = state.value.copyWith(phase: HubConnectionPhase.reconnecting);
    _scheduleRetry();
  }
}
