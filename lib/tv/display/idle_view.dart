import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

/// How the Pi link looks as a small dot next to the status line.
enum IdleLink { connected, connecting, unreachable }

/// What the TV shows while a phone is paired and nothing plays: a large soft
/// clock and date, one status line and a small Pi dot on a near-black screen.
///
/// The whole group drifts slowly to a new spot every [driftEvery], so no pixel
/// stays lit for long and nothing flickers.
class IdleView extends StatefulWidget {
  const IdleView({
    super.key,
    required this.status,
    this.link = IdleLink.connected,
    this.now,
    this.driftEvery = const Duration(minutes: 1),
    this.driftDuration = const Duration(seconds: 20),
    this.random,
  });

  /// The one line under the clock.
  final String status;
  final IdleLink link;

  /// The wall clock; [DateTime.now] when null (tests pass their own).
  final DateTime Function()? now;
  final Duration driftEvery;

  /// How long the move to the next spot takes (slow on purpose).
  final Duration driftDuration;
  final Random? random;

  /// The text of the status line while the Pi is reachable.
  static const readyText = 'Ready — choose something on your phone';

  static const background = Color(0xFF050505);

  @override
  State<IdleView> createState() => _IdleViewState();
}

class _IdleViewState extends State<IdleView> {
  late final Random _random = widget.random ?? Random();
  Timer? _clockTimer;
  Timer? _driftTimer;
  late DateTime _now = _read();
  Alignment _spot = const Alignment(0, -0.05);

  DateTime _read() => (widget.now ?? DateTime.now)();

  @override
  void initState() {
    super.initState();
    _scheduleClock();
    _driftTimer = Timer.periodic(widget.driftEvery, (_) => _drift());
  }

  @override
  void dispose() {
    _clockTimer?.cancel();
    _driftTimer?.cancel();
    super.dispose();
  }

  /// Wakes up when the minute changes.
  void _scheduleClock() {
    final t = _read();
    final next = DateTime(
      t.year,
      t.month,
      t.day,
      t.hour,
      t.minute + 1,
    ).difference(t);
    _clockTimer = Timer(next + const Duration(milliseconds: 50), () {
      if (!mounted) return;
      setState(() => _now = _read());
      _scheduleClock();
    });
  }

  /// A new spot at least a third of the screen away from the last one, kept
  /// clear of the edges.
  void _drift() {
    if (!mounted) return;
    _now = _read(); // also corrects the clock after a time jump
    Alignment next;
    var tries = 0;
    do {
      next = Alignment(
        (_random.nextDouble() * 2 - 1) * 0.5,
        (_random.nextDouble() * 2 - 1) * 0.4,
      );
      tries++;
    } while (tries < 20 &&
        (next.x - _spot.x).abs() + (next.y - _spot.y).abs() < 0.35);
    setState(() => _spot = next);
  }

  Color get _dotColor => switch (widget.link) {
    IdleLink.connected => const Color(0xFF58C47A),
    IdleLink.connecting => const Color(0xFFE0B04A),
    IdleLink.unreachable => const Color(0xFFE5645A),
  };

  String get _dotLabel => switch (widget.link) {
    IdleLink.connected => 'Pi connected',
    IdleLink.connecting => 'Connecting to the Pi',
    IdleLink.unreachable => 'Pi not reachable',
  };

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.sizeOf(context).height;
    // The TV's language and its 12 or 24 hour setting.
    final l10n = MaterialLocalizations.of(context);
    final clock = l10n.formatTimeOfDay(
      TimeOfDay.fromDateTime(_now),
      alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
    );
    return ColoredBox(
      key: const Key('idle-view'),
      color: IdleView.background,
      child: AnimatedAlign(
        alignment: _spot,
        duration: widget.driftDuration,
        curve: Curves.easeInOutCubic,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.sizeOf(context).width * 0.9,
          ),
          child: Column(
            key: const Key('idle-group'),
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                clock,
                key: const Key('idle-clock'),
                style: TextStyle(
                  color: const Color(0xFFEDEDED),
                  fontSize: height * 0.26,
                  fontWeight: FontWeight.w200,
                  height: 1,
                  letterSpacing: height * 0.004,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              SizedBox(height: height * 0.02),
              Text(
                l10n.formatFullDate(_now),
                key: const Key('idle-date'),
                style: TextStyle(
                  color: const Color(0xFF8E8E8E),
                  fontSize: height * 0.045,
                  fontWeight: FontWeight.w300,
                ),
              ),
              SizedBox(height: height * 0.07),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Semantics(
                    label: _dotLabel,
                    child: Container(
                      key: const Key('idle-dot'),
                      width: height * 0.016,
                      height: height * 0.016,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _dotColor,
                      ),
                    ),
                  ),
                  SizedBox(width: height * 0.018),
                  Flexible(
                    child: Text(
                      widget.status,
                      key: const Key('display-status'),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: const Color(0xFF9A9A9A),
                        fontSize: height * 0.034,
                        fontWeight: FontWeight.w300,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
