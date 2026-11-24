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

class _DisplayScreenState extends State<DisplayScreen> {
  bool _menuOpen = false;
  Timer? _backTimer;
  bool _backFired = false;
  bool _backDown = false;

  DisplayClient get _client => widget.client;

  @override
  void initState() {
    super.initState();
    _client.addListener(_onChanged);
    unawaited(_client.start());
  }

  @override
  void dispose() {
    _backTimer?.cancel();
    _client.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _openMenu() async {
    if (_menuOpen) return;
    // The picture gives way: the spikes bring their own SurfaceView.
    await _client.player.viewDisposed();
    if (!mounted) return;
    setState(() => _menuOpen = true);
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
          _backTimer = Timer(widget.holdBack, () {
            _backFired = true;
            unawaited(_client.forgetAllPhones());
          });
        }
      } else if (event is KeyUpEvent) {
        _backDown = false;
        _backTimer?.cancel();
        _backTimer = null;
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
            ],
          ),
        ),
      ),
    );
  }

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
