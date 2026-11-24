import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../video_spike/spike_native.dart';
import 'display_client.dart';
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
  });

  final DisplayClient client;

  /// The screen the Menu key opens. `onPairPhone` is wired by the caller.
  final Widget Function(BuildContext context, VoidCallback onPairPhone)
  menuBuilder;

  /// Replaces the native Media3 platform view; calls `onCreated` once built.
  final Widget Function(void Function(int id) onCreated)? media3View;
  final Duration holdBack;

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

  DisplayClient get _client => widget.client;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _client.addListener(_onChanged);
    unawaited(_client.start());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _backTimer?.cancel();
    _holdClock?.cancel();
    _noticeTimer?.cancel();
    _client.removeListener(_onChanged);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // A key-up that never arrives must not leave Back "held".
    _resetBack();
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
    if (mounted) setState(() {});
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
    if (key == LogicalKeyboardKey.contextMenu ||
        key == LogicalKeyboardKey.info) {
      unawaited(_openMenu());
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
              if (!_client.player.hasItem && !_client.needsPairing)
                _idleMessage(height),
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

  Widget _idleMessage(double height) {
    final status = _client.statusText;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'TV Saver',
            style: TextStyle(
              color: Colors.white,
              fontSize: height * 0.07,
              fontWeight: FontWeight.w600,
            ),
          ),
          SizedBox(height: height * 0.02),
          Text(
            status.isEmpty ? 'Press Play in the phone app.' : status,
            key: const Key('display-status'),
            style: TextStyle(
              color: const Color(0xFFD0D0D0),
              fontSize: height * 0.04,
            ),
          ),
        ],
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
