import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'display_player.dart';

/// Shows the photo the player chose, full screen.
///
/// A new photo is decoded first (at the size of the screen, never larger than
/// the file, one decode at a time, the newest request wins). The photo on
/// screen stays until the next one is ready, then they cross-fade (or cut).
/// Ken Burns is a slow GPU scale, never a re-decode.
class ImageStage extends StatefulWidget {
  const ImageStage({super.key, required this.slots});

  final ValueListenable<ImageSlot?> slots;

  @override
  State<ImageStage> createState() => _ImageStageState();
}

class _ImageStageState extends State<ImageStage> {
  ImageSlot? _shown;
  int _request = 0;
  bool _decoding = false;
  ImageSlot? _waiting;

  @override
  void initState() {
    super.initState();
    widget.slots.addListener(_onSlot);
    if (widget.slots.value != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _onSlot());
    }
  }

  @override
  void didUpdateWidget(ImageStage old) {
    super.didUpdateWidget(old);
    if (old.slots != widget.slots) {
      old.slots.removeListener(_onSlot);
      widget.slots.addListener(_onSlot);
      _onSlot();
    }
  }

  @override
  void dispose() {
    widget.slots.removeListener(_onSlot);
    super.dispose();
  }

  ImageProvider _provider(ImageSlot slot) {
    final view = View.of(context);
    final size = view.physicalSize;
    return ResizeImage(
      FileImage(slot.file),
      width: size.width.round(),
      height: size.height.round(),
      policy: ResizeImagePolicy.fit,
    );
  }

  void _onSlot() {
    final slot = widget.slots.value;
    _request++;
    if (slot == null) {
      _waiting = null;
      if (mounted) setState(() => _shown = null);
      return;
    }
    _waiting = slot;
    if (!_decoding) unawaited(_decodeNext());
  }

  Future<void> _decodeNext() async {
    _decoding = true;
    try {
      while (_waiting != null && mounted) {
        final slot = _waiting!;
        final mine = _request;
        _waiting = null;
        var failed = false;
        try {
          // precacheImage reports a failure to onError and then completes.
          await precacheImage(
            _provider(slot),
            context,
            onError: (Object _, StackTrace? _) => failed = true,
          );
        } catch (_) {
          failed = true;
        }
        // An unreadable file: skip this photo; the player moves on.
        if (failed) continue;
        if (!mounted) return;
        // A newer photo (or "nothing") arrived while this one decoded.
        if (mine != _request) continue;
        setState(() => _shown = slot);
      }
    } finally {
      _decoding = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final slot = _shown;
    if (slot == null) return const SizedBox.shrink();
    return AnimatedSwitcher(
      duration: slot.crossfade
          ? const Duration(milliseconds: 800)
          : Duration.zero,
      child: _Slide(
        key: ValueKey(slot.nonce),
        slot: slot,
        provider: _provider(slot),
      ),
    );
  }
}

class _Slide extends StatefulWidget {
  const _Slide({super.key, required this.slot, required this.provider});

  final ImageSlot slot;
  final ImageProvider provider;

  @override
  State<_Slide> createState() => _SlideState();
}

class _SlideState extends State<_Slide> with SingleTickerProviderStateMixin {
  AnimationController? _zoom;

  @override
  void initState() {
    super.initState();
    if (widget.slot.kenBurns) {
      _zoom = AnimationController(
        vsync: this,
        duration: Duration(
          milliseconds: widget.slot.durationMs < 1000
              ? 1000
              : widget.slot.durationMs,
        ),
      )..forward();
    }
  }

  @override
  void dispose() {
    _zoom?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Widget image = Image(
      image: widget.provider,
      fit: BoxFit.contain,
      filterQuality: FilterQuality.high,
      gaplessPlayback: true,
      isAntiAlias: true,
    );
    final zoom = _zoom;
    if (zoom != null) {
      image = ScaleTransition(
        scale: Tween<double>(begin: 1.0, end: 1.08).animate(zoom),
        child: image,
      );
    }
    return ColoredBox(
      color: Colors.black,
      child: SizedBox.expand(child: Center(child: image)),
    );
  }
}
