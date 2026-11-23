import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import 'spike_log.dart';
import 'spike_native.dart';

/// Builds the `video_player` controller for a path; injected for tests.
typedef SpikeControllerFactory = VideoPlayerController Function(
  String path,
  VideoViewType viewType,
);

VideoPlayerController defaultSpikeController(
  String path,
  VideoViewType viewType,
) => VideoPlayerController.file(File(path), viewType: viewType);

/// How long into playback the `VideoSpike:` line is written, so the display
/// mode "during" playback has settled (a refresh-rate switch takes ~1-2 s).
const spikeReportDelay = Duration(seconds: 4);

/// Plays one clip full screen with the chosen [view] and [loop] strategy and
/// logs a `VideoSpike:` line a few seconds in and on exit.
///
/// A clip that cannot be played shows "cannot play" plus the reason instead of
/// crashing. Back / Escape leaves ([onExit]); OK hides or shows the overlay.
class SpikePlayer extends StatefulWidget {
  const SpikePlayer({
    super.key,
    required this.path,
    required this.view,
    required this.loop,
    required this.native,
    required this.onExit,
    this.log = spikeLog,
    this.controllerFactory = defaultSpikeController,
    this.media3View,
  });

  final String path;
  final SpikeView view;
  final SpikeLoop loop;
  final SpikeNative native;
  final VoidCallback onExit;
  final void Function(String line) log;
  final SpikeControllerFactory controllerFactory;

  /// Replaces the native Media3 platform view; calls `onCreated` once built.
  /// Injected for tests.
  final Widget Function(void Function(int id) onCreated)? media3View;

  @override
  State<SpikePlayer> createState() => _SpikePlayerState();
}

class _SpikePlayerState extends State<SpikePlayer> {
  VideoPlayerController? _controller;
  Timer? _reportTimer;
  Timer? _statsTimer;
  String? _error;
  bool _overlay = true;
  bool _exiting = false;
  DisplayModeInfo? _before;
  DisplayModeInfo? _now;
  ClipProbe? _probe;
  Media3Stats? _stats;

  String get _clip => widget.path.split(RegExp(r'[\\/]')).last;
  bool get _isMedia3 => widget.view == SpikeView.media3;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  Future<void> _start() async {
    _before = await widget.native.displayInfo();
    _now = _before;
    _probe = await widget.native.probe(widget.path);
    if (!mounted) return;
    if (!_isMedia3) {
      final controller = widget.controllerFactory(
        widget.path,
        widget.view == SpikeView.platformView
            ? VideoViewType.platformView
            : VideoViewType.textureView,
      );
      _controller = controller;
      try {
        await controller.initialize();
        await controller.setLooping(true);
        await controller.play();
      } catch (e) {
        if (!mounted) return;
        _fail(e);
        return;
      }
      if (!mounted) return;
      setState(() {});
    }
    // Media3 starts when its platform view exists (_onMedia3ViewCreated).
    _reportTimer = Timer(spikeReportDelay, () => unawaited(_report('playing')));
    _statsTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
      if (_isMedia3) {
        final s = await widget.native.media3Stats();
        if (!mounted || s == null) return;
        setState(() => _stats = s);
        if (s.error != null && _error == null) _fail(s.error!);
      }
    });
  }

  void _fail(Object e) {
    final reason = e is PlatformException
        ? (e.message ?? e.code)
        : e.toString().replaceFirst('Exception: ', '');
    if (mounted) setState(() => _error = reason);
    widget.log(
      videoSpikeLogLine(
        clip: _clip,
        view: widget.view,
        loop: widget.loop,
        phase: 'failed',
        decoder: _probe?.decoder,
        hdr: _probe?.hdr,
        displayBefore: _before,
        displayNow: _before,
        note: 'cannot play: $reason',
      ),
    );
  }

  Future<void> _onMedia3ViewCreated(int id) async {
    if (!mounted) {
      // Left before the view existed: don't leave an orphan player running.
      await widget.native.media3Release();
      return;
    }
    try {
      await widget.native.media3Open(widget.path, _loopArg);
    } catch (e) {
      _fail(e);
    }
  }

  String get _loopArg =>
      widget.loop == SpikeLoop.playlist ? 'playlist' : 'repeatOne';

  Future<void> _report(String phase) async {
    _now = await widget.native.displayInfo() ?? _now;
    final stats = _isMedia3 ? await widget.native.media3Stats() : null;
    if (stats != null && mounted) _stats = stats;
    final err = stats?.error ?? _controller?.value.errorDescription;
    if (err != null && _error == null && mounted) {
      setState(() => _error = err);
    }
    widget.log(
      videoSpikeLogLine(
        clip: _clip,
        view: widget.view,
        loop: widget.loop,
        phase: phase,
        decoder: stats?.decoder ?? _probe?.decoder,
        hdr: stats?.hdr ?? _probe?.hdr,
        displayBefore: _before,
        displayNow: _now,
        droppedFrames: stats?.droppedFrames,
        clipFps: stats?.frameRate ?? _probe?.frameRate,
        note: err == null ? null : 'cannot play: $err',
      ),
    );
  }

  Future<void> _exit() async {
    if (_exiting) return;
    _exiting = true;
    _reportTimer?.cancel();
    await _report('stopped');
    widget.onExit();
  }

  @override
  void dispose() {
    _reportTimer?.cancel();
    _statsTimer?.cancel();
    _controller?.dispose();
    if (_isMedia3) unawaited(widget.native.media3Release());
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
              if (_error == null) Center(child: _video()),
              if (_error != null)
                Center(
                  child: Text(
                    'cannot play: $_error',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: height * .05,
                    ),
                  ),
                ),
              if (_overlay) _overlayText(height),
            ],
          ),
        ),
      ),
    );
  }

  Widget _video() {
    if (_isMedia3) {
      return widget.media3View?.call(_onMedia3ViewCreated) ?? _media3View();
    }
    final c = _controller;
    if (c == null || !c.value.isInitialized) return const SizedBox.shrink();
    return AspectRatio(aspectRatio: c.value.aspectRatio, child: VideoPlayer(c));
  }

  /// The native SurfaceView (hybrid composition so it is a real SurfaceView).
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

  Widget _overlayText(double height) {
    final s = _stats;
    final lines = <String>[
      '$_clip  |  ${widget.view.label}  |  ${widget.loop.label}',
      'display ${_now?.label ?? '?'}  |  hdr ${s?.hdr ?? _probe?.hdr ?? '?'}',
      if (_isMedia3)
        'decoder ${s?.decoder ?? '?'}  |  dropped ${s?.droppedFrames ?? '?'}'
            '  |  item ${s?.item ?? '?'}  |  ${s?.position.inMilliseconds ?? 0} ms'
      else
        'decoder ${_probe?.decoder ?? '?'}  |  dropped n/a (video_player)',
      'OK: hide overlay   Back: stop',
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
}
