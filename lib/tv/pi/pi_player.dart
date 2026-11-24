import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../video_spike/spike_native.dart';
import 'pi_config.dart';

void _defaultLog(String line) => debugPrint(line);

/// Default `/health` probe against the Pi server: HTTP 200 means reachable.
Future<bool> defaultHealthCheck(Uri healthUri) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
  try {
    final req = await client.getUrl(healthUri);
    final res = await req.close();
    await res.drain<void>();
    return res.statusCode == HttpStatus.ok;
  } catch (_) {
    return false;
  } finally {
    client.close(force: true);
  }
}

/// Streams a hard-coded Pi playlist via the native Media3 SurfaceView with
/// `Authorization: Bearer` headers, Left/Right prev/next, OK overlay toggle,
/// Back to stop, and `/health` polling on outage (stopping on `401`).
class PiPlayer extends StatefulWidget {
  const PiPlayer({
    super.key,
    required this.config,
    required this.native,
    required this.onExit,
    this.log = _defaultLog,
    this.healthCheck = defaultHealthCheck,
    this.media3View,
    this.statsInterval = const Duration(seconds: 1),
    this.reconnectInterval = const Duration(seconds: 3),
  });

  final PiConfig config;
  final PiVideoNative native;
  final VoidCallback onExit;
  final void Function(String line) log;
  final Future<bool> Function(Uri healthUri) healthCheck;

  /// Replaces the native Media3 platform view; calls `onCreated` once built.
  final Widget Function(void Function(int id) onCreated)? media3View;
  final Duration statsInterval;
  final Duration reconnectInterval;

  @override
  State<PiPlayer> createState() => _PiPlayerState();
}

class _PiPlayerState extends State<PiPlayer> {
  Timer? _statsTimer;
  Timer? _reconnectTimer;
  Media3Stats? _stats;
  DisplayModeInfo? _display;

  bool _overlay = true;
  bool _exiting = false;
  bool _viewCreated = false;
  bool _opening = false;
  bool _reconnecting = false;
  bool _probing = false;
  bool _authFailed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_initDisplay());
    _statsTimer = Timer.periodic(widget.statsInterval, (_) {
      unawaited(_pollStats());
    });
  }

  Future<void> _initDisplay() async {
    final info = await widget.native.displayInfo();
    if (mounted) setState(() => _display = info);
  }

  Future<void> _onMedia3ViewCreated(int id) async {
    if (!mounted || _exiting) {
      await widget.native.media3Release();
      return;
    }
    if (_viewCreated) return;
    _viewCreated = true;
    await _openPlaylist();
  }

  Future<void> _openPlaylist() async {
    if (!mounted || _exiting || _authFailed || !_viewCreated) return;
    _opening = true;
    try {
      final urls = [for (final u in widget.config.playlistUris) u.toString()];
      await widget.native.media3OpenHttp(urls, widget.config.authHeaders);
    } catch (e) {
      _enterReconnect(e.toString());
    } finally {
      _opening = false;
    }
  }

  Future<void> _pollStats() async {
    if (!mounted || _exiting || _authFailed || _reconnecting || _opening) {
      return;
    }
    final s = await widget.native.media3Stats();
    if (!mounted || _exiting || _authFailed || _reconnecting || _opening) {
      return;
    }
    if (s == null) return;
    setState(() => _stats = s);
    if (s.httpStatus == HttpStatus.unauthorized) {
      _handleAuthFailure();
      return;
    }
    if (s.error != null) {
      _enterReconnect(s.error!);
    }
  }

  void _handleAuthFailure() {
    if (_authFailed) return;
    _authFailed = true;
    _reconnecting = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _statsTimer?.cancel();
    _statsTimer = null;
    unawaited(widget.native.media3Release());
    widget.log('PiStream: auth failed (401)');
    if (mounted) setState(() {});
  }

  void _enterReconnect(String reason) {
    if (_reconnecting || _authFailed || _exiting) return;
    _reconnecting = true;
    unawaited(widget.native.media3Release());
    widget.log('PiStream: disconnected ($reason)');
    if (mounted) setState(() {});
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer.periodic(widget.reconnectInterval, (_) {
      unawaited(_probeHealth());
    });
  }

  Future<void> _probeHealth() async {
    if (!_reconnecting || _probing || _authFailed || _exiting || !mounted) {
      return;
    }
    _probing = true;
    try {
      final ok = await widget.healthCheck(widget.config.healthUri);
      if (!ok || !_reconnecting || _authFailed || _exiting || !mounted) return;
      _reconnectTimer?.cancel();
      _reconnectTimer = null;
      _reconnecting = false;
      widget.log('PiStream: reconnected');
      setState(() {});
      await _openPlaylist();
    } finally {
      _probing = false;
    }
  }

  Future<void> _exit() async {
    if (_exiting) return;
    _exiting = true;
    _statsTimer?.cancel();
    _reconnectTimer?.cancel();
    await widget.native.media3Release();
    widget.onExit();
  }

  @override
  void dispose() {
    _exiting = true;
    _statsTimer?.cancel();
    _reconnectTimer?.cancel();
    unawaited(widget.native.media3Release());
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape ||
        key == LogicalKeyboardKey.goBack ||
        key == LogicalKeyboardKey.browserBack) {
      unawaited(_exit());
      return KeyEventResult.handled;
    }
    if (_authFailed) return KeyEventResult.ignored;
    if (key == LogicalKeyboardKey.arrowRight) {
      unawaited(widget.native.media3Next());
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      unawaited(widget.native.media3Prev());
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.gameButtonA) {
      setState(() => _overlay = !_overlay);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.sizeOf(context).height;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_exit());
      },
      child: Focus(
        autofocus: true,
        onKeyEvent: _onKey,
        child: ColoredBox(
          color: Colors.black,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Center(
                child:
                    widget.media3View?.call(_onMedia3ViewCreated) ??
                    _media3View(),
              ),
              if (_authFailed) _authErrorBox(height),
              if (_reconnecting && !_authFailed) _reconnectingBox(height),
              if (_overlay && !_authFailed) _overlayBox(height),
            ],
          ),
        ),
      ),
    );
  }

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

  String _currentClip() {
    final idx = _stats?.item;
    final list = widget.config.playlist;
    if (idx != null && idx >= 0 && idx < list.length) return list[idx];
    return list.first;
  }

  String _formatDuration(Duration d) {
    final totalSecs = d.inSeconds;
    final mins = totalSecs ~/ 60;
    final secs = totalSecs % 60;
    return '$mins:${secs.toString().padLeft(2, '0')}';
  }

  Widget _overlayBox(double height) {
    final s = _stats;
    final pos = _formatDuration(s?.position ?? Duration.zero);
    final dur = s?.duration != null ? ' / ${_formatDuration(s!.duration!)}' : '';
    final lines = <String>[
      'clip ${_currentClip()}  (${(_stats?.item ?? 0) + 1}/${widget.config.playlist.length})',
      'decoder ${s?.decoder ?? '?'}  |  HDR ${s?.hdr ?? '?'}'
          '  |  display ${_display?.label ?? '?'}',
      'dropped ${s?.droppedFrames ?? '?'}  |  pos $pos$dur',
      'Left/Right: prev/next   OK: hide overlay   Back: stop',
    ];
    return Positioned(
      left: height * .06,
      top: height * .05,
      child: DecoratedBox(
        decoration: const BoxDecoration(color: Color(0xAA000000)),
        child: Padding(
          padding: EdgeInsets.all(height * .015),
          child: Text(
            lines.join('\n'),
            style: TextStyle(color: Colors.white, fontSize: height * .028),
          ),
        ),
      ),
    );
  }

  Widget _reconnectingBox(double height) => Center(
    child: DecoratedBox(
      decoration: const BoxDecoration(color: Color(0xCC000000)),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: height * .04,
          vertical: height * .03,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Reconnecting…',
              style: TextStyle(
                color: Colors.white,
                fontSize: height * .055,
                fontWeight: FontWeight.w600,
              ),
            ),
            SizedBox(height: height * .015),
            Text(
              'Waiting for Pi at ${widget.config.host}:${widget.config.port}/health',
              style: TextStyle(
                color: const Color(0xFFD0D0D0),
                fontSize: height * .032,
              ),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _authErrorBox(double height) => Center(
    child: DecoratedBox(
      decoration: const BoxDecoration(color: Color(0xE6000000)),
      child: Padding(
        padding: EdgeInsets.all(height * .04),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'auth failed (401)',
              style: TextStyle(
                color: Colors.white,
                fontSize: height * .06,
                fontWeight: FontWeight.w600,
              ),
            ),
            SizedBox(height: height * .02),
            Text(
              'Re-run setup_phase2.sh to push the current Pi token:',
              style: TextStyle(
                color: const Color(0xFFD0D0D0),
                fontSize: height * .035,
              ),
            ),
            SizedBox(height: height * .01),
            Text(
              setupPhase2Hint,
              style: TextStyle(
                color: const Color(0xFFD0D0D0),
                fontSize: height * .032,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
