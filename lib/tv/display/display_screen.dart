import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import 'package:hub_core/hub_core.dart';

import '../video_spike/spike_native.dart';
import 'awake_guard.dart';
import 'display_client.dart';
import 'idle_view.dart';
import 'info_overlay.dart';
import 'playback_log.dart';
import 'image_stage.dart';
import 'pairing_view.dart';

/// How long Back is held to forget every phone.
const forgetAllHold = Duration(seconds: 10);

bool _isBack(LogicalKeyboardKey key) =>
    key == LogicalKeyboardKey.goBack ||
    key == LogicalKeyboardKey.escape ||
    key == LogicalKeyboardKey.browserBack;

/// The TV's home screen: the Media3 picture the Pi chose, the pairing code
/// while no phone is paired, and the remote.
///
/// OK pauses and resumes, Left/Right are previous/next, FF/RW seek 30 s, Menu
/// opens [menuBuilder], holding Back for [holdBack] sends `devices.forgetAll`.
class DisplayScreen extends StatefulWidget {
  const DisplayScreen({
    super.key,
    required this.client,
    required this.menuBuilder,
    this.media3View,
    this.holdBack = forgetAllHold,
    this.now,
    this.awake = const WakelockAwakeGuard(),
    this.infoFor = const Duration(seconds: 8),
    this.log = const NoPlaybackLog(),
    this.heartbeat = const Duration(minutes: 5),
  });

  final DisplayClient client;

  /// The screen the Menu key opens. `onPairPhone` is wired by the caller.
  final Widget Function(BuildContext context, VoidCallback onPairPhone)
  menuBuilder;

  /// Replaces the native Media3 platform view; calls `onCreated` once built.
  final Widget Function(void Function(int id) onCreated)? media3View;
  final Duration holdBack;

  /// The idle clock's time source (tests).
  final DateTime Function()? now;

  /// Keeps the screen on while something plays.
  final AwakeGuard awake;

  /// How long the Info key's overlay stays.
  final Duration infoFor;

  /// Where lifecycle changes, new items and heartbeats are noted.
  final PlaybackLog log;

  /// How often a heartbeat line is written while the screen is up.
  final Duration heartbeat;

  @override
  State<DisplayScreen> createState() => _DisplayScreenState();
}

class _DisplayScreenState extends State<DisplayScreen>
    with WidgetsBindingObserver {
  bool _menuOpen = false;
  Timer? _backTimer;
  bool _backFired = false;
  bool _backDown = false;

  /// Seconds Back has been held (a one-second clock while it is down).
  int _heldSeconds = 0;
  Timer? _holdClock;

  /// What `devices.forgetAll` did, shown for a few seconds.
  String? _notice;
  Timer? _noticeTimer;

  /// The Info key's overlay: shown for [DisplayScreen.infoFor], redrawn each
  /// second so the time moves.
  bool _infoVisible = false;
  Timer? _infoHide;
  Timer? _infoTick;
  Timer? _heartbeat;
  String? _loggedItem;

  DisplayClient get _client => widget.client;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _client.addListener(_onChanged);
    _client.player.active.addListener(_syncAwake);
    _syncAwake();
    widget.log.event('start');
    _heartbeat = Timer.periodic(widget.heartbeat, (_) => _note('heartbeat'));
    unawaited(_client.start());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _backTimer?.cancel();
    _holdClock?.cancel();
    _noticeTimer?.cancel();
    _infoHide?.cancel();
    _infoTick?.cancel();
    _heartbeat?.cancel();
    widget.log.event('stop');
    _client.removeListener(_onChanged);
    _client.player.active.removeListener(_syncAwake);
    unawaited(widget.awake.release());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // A key-up that never arrives must not leave Back "held".
    _resetBack();
    _note(state.name);
    if (state == AppLifecycleState.resumed) {
      // The system may have brought its bars or its sleep back meanwhile.
      unawaited(
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky),
      );
      _syncAwake();
    }
  }

  /// Holds the wake lock exactly while something plays.
  void _syncAwake() {
    unawaited(
      _client.player.active.value
          ? widget.awake.hold()
          : widget.awake.release(),
    );
  }

  void _toggleInfo() {
    _infoHide?.cancel();
    _infoTick?.cancel();
    if (_infoVisible) {
      setState(() => _infoVisible = false);
      return;
    }
    setState(() => _infoVisible = true);
    _infoHide = Timer(widget.infoFor, () {
      _infoTick?.cancel();
      if (mounted) setState(() => _infoVisible = false);
    });
    _infoTick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  /// Forgets a Back press in progress (menu opened, focus or app lost).
  void _resetBack() {
    _backTimer?.cancel();
    _backTimer = null;
    _holdClock?.cancel();
    _holdClock = null;
    _backDown = false;
    _heldSeconds = 0;
    if (mounted) setState(() {});
  }

  Future<void> _forgetAll() async {
    final ok = await _client.forgetAllPhones();
    if (!mounted) return;
    _showNotice(
      ok
          ? 'All phones forgotten. Pair a phone with the code.'
          : 'Could not forget the phones. Is the Pi reachable?',
    );
  }

  void _showNotice(String text) {
    _noticeTimer?.cancel();
    setState(() => _notice = text);
    _noticeTimer = Timer(const Duration(seconds: 5), () {
      if (mounted) setState(() => _notice = null);
    });
  }

  void _onChanged() {
    final id = _client.player.itemId;
    if (id != _loggedItem) {
      _loggedItem = id;
      _note('item');
    }
    if (mounted) setState(() {});
  }

  /// One line in the playback log with what is on screen now.
  void _note(String event) {
    final s = _client.player.snapshot;
    widget.log.event(
      event,
      item: s.itemId,
      state: s.state,
      detail: event == 'heartbeat'
          ? '${s.positionMs}ms ${_client.connected ? 'online' : 'offline'}'
          : null,
    );
  }

  Future<void> _openMenu() async {
    if (_menuOpen) return; // A second press while it opens does nothing.
    _resetBack();
    setState(() => _menuOpen = true);
    // The picture gives way: the spikes bring their own SurfaceView.
    await _client.player.viewDisposed();
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (ctx) => widget.menuBuilder(ctx, _client.pairAnotherPhone),
      ),
    );
    if (mounted) setState(() => _menuOpen = false);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final key = event.logicalKey;
    if (_isBack(key)) {
      if (event is KeyDownEvent) {
        if (!_backDown) {
          _backDown = true;
          _backFired = false;
          _backTimer?.cancel();
          _heldSeconds = 0;
          _backTimer = Timer(widget.holdBack, () {
            _backFired = true;
            _holdClock?.cancel();
            _holdClock = null;
            setState(() => _heldSeconds = 0);
            unawaited(_forgetAll());
          });
          _holdClock = Timer.periodic(const Duration(seconds: 1), (_) {
            if (mounted) setState(() => _heldSeconds++);
          });
        }
      } else if (event is KeyUpEvent) {
        final fired = _backFired;
        _resetBack();
        _backFired = fired;
        // A short press only closes a pairing screen the user asked for.
        if (!_backFired) _client.stopPairing();
      }
      return KeyEventResult.handled;
    }
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (key == LogicalKeyboardKey.contextMenu) {
      unawaited(_openMenu());
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.info) {
      if (!_client.needsPairing && _client.player.hasItem) _toggleInfo();
      return KeyEventResult.handled;
    }
    if (_client.needsPairing) return KeyEventResult.ignored;
    if (key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.gameButtonA ||
        key == LogicalKeyboardKey.mediaPlayPause) {
      unawaited(_client.togglePause());
    } else if (key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.mediaTrackNext) {
      unawaited(_client.next());
    } else if (key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.mediaTrackPrevious) {
      unawaited(_client.prev());
    } else if (key == LogicalKeyboardKey.mediaFastForward) {
      unawaited(_client.seekBy(remoteSeekMs));
    } else if (key == LogicalKeyboardKey.mediaRewind) {
      unawaited(_client.seekBy(-remoteSeekMs));
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.sizeOf(context).height;
    return PopScope(
      canPop: false,
      child: Focus(
        autofocus: true,
        onKeyEvent: _onKey,
        onFocusChange: (focused) {
          if (!focused) _resetBack();
        },
        child: ColoredBox(
          color: Colors.black,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (!_menuOpen)
                Center(
                  child:
                      widget.media3View?.call(_onMedia3ViewCreated) ??
                      _media3View(),
                ),
              Positioned.fill(child: ImageStage(slots: _client.player.image)),
              if (!_client.player.hasItem && !_client.needsPairing) _idleView(),
              if (_infoVisible && _client.player.hasItem)
                InfoOverlay(
                  snapshot: _client.player.snapshot,
                  info: _client.player.info,
                  online: _client.connected,
                  cached: _client.player.fromCache,
                ),
              if (_client.needsPairing)
                Positioned.fill(
                  child: PairingView(
                    pairing: _client.pairing,
                    error: _client.pairingError,
                  ),
                ),
              if (_heldSeconds >= 3 && _backDown)
                _banner(
                  height,
                  'Keep holding Back to forget all phones: '
                  '${(widget.holdBack.inSeconds - _heldSeconds).clamp(0, 99)} s',
                  key: const Key('back-countdown'),
                )
              else if (_notice != null)
                _banner(height, _notice!, key: const Key('display-notice')),
            ],
          ),
        ),
      ),
    );
  }

  Widget _banner(double height, String text, {required Key key}) => Positioned(
    left: 0,
    right: 0,
    bottom: height * 0.08,
    child: Center(
      child: DecoratedBox(
        decoration: const BoxDecoration(color: Color(0xCC000000)),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: height * 0.04,
            vertical: height * 0.02,
          ),
          child: Text(
            text,
            key: key,
            style: TextStyle(color: Colors.white, fontSize: height * 0.04),
          ),
        ),
      ),
    ),
  );

  Widget _idleView() {
    final status = _client.statusText;
    final phase = _client.hub.phase;
    final link = switch (phase) {
      HubConnectionPhase.connected => IdleLink.connected,
      // Still trying, or in the handshake.
      HubConnectionPhase.connecting ||
      HubConnectionPhase.reconnecting ||
      HubConnectionPhase.disconnected ||
      HubConnectionPhase.awaitingPin => IdleLink.connecting,
      HubConnectionPhase.offline ||
      HubConnectionPhase.appNotOpen ||
      HubConnectionPhase.wrongTv ||
      HubConnectionPhase.replaced ||
      HubConnectionPhase.needsTvUpdate => IdleLink.unreachable,
    };
    return Positioned.fill(
      child: IdleView(
        status: link == IdleLink.connected || status.isEmpty
            ? IdleView.readyText
            : status,
        link: link,
        now: widget.now,
      ),
    );
  }

  Future<void> _onMedia3ViewCreated(int id) => _client.player.viewCreated();

  Widget _media3View() => PlatformViewLink(
    viewType: media3ViewType,
    surfaceFactory: (context, controller) => AndroidViewSurface(
      controller: controller as AndroidViewController,
      gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{},
      hitTestBehavior: PlatformViewHitTestBehavior.transparent,
    ),
    onCreatePlatformView: (params) {
      return PlatformViewsService.initExpensiveAndroidView(
          id: params.id,
          viewType: media3ViewType,
          layoutDirection: TextDirection.ltr,
          creationParamsCodec: const StandardMessageCodec(),
          onFocus: () => params.onFocusChanged(true),
        )
        ..addOnPlatformViewCreatedListener(params.onPlatformViewCreated)
        ..addOnPlatformViewCreatedListener(_onMedia3ViewCreated)
        ..create();
    },
  );
}
