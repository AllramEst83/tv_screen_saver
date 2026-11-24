import 'package:flutter/material.dart';

import 'display_player.dart';

/// `3:07` or `1:02:03`.
String clockText(int ms) {
  final total = (ms < 0 ? 0 : ms) ~/ 1000;
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  final s = total % 60;
  String two(int v) => v.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(s)}' : '$m:${two(s)}';
}

/// What the remote's Info key shows for a few seconds: the name of what is on
/// screen, its place in the playlist, how far along it is, and, only here,
/// whether the Pi is out of reach.
class InfoOverlay extends StatelessWidget {
  const InfoOverlay({
    super.key,
    required this.snapshot,
    required this.info,
    required this.online,
    required this.cached,
  });

  final PlayerSnapshot snapshot;
  final ItemInfo? info;

  /// The TV is connected to the Pi.
  final bool online;

  /// The item plays from the TV's own cache.
  final bool cached;

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.sizeOf(context).height;
    final name = info?.name ?? snapshot.itemId ?? '';
    final index = info?.index;
    final count = info?.count;
    final duration = snapshot.durationMs;
    final position = snapshot.positionMs;
    final progress = duration != null && duration > 0
        ? (position / duration).clamp(0.0, 1.0)
        : null;
    final style = TextStyle(color: Colors.white, fontSize: height * 0.035);
    final small = style.copyWith(
      fontSize: height * 0.028,
      color: Colors.white70,
    );
    final place = [
      if (index != null && count != null) '${index + 1} of $count',
      if (info != null) (info!.isImage ? 'Photo' : 'Video'),
      if (snapshot.state == 'paused') 'Paused',
    ].join(' · ');
    return Positioned(
      left: height * 0.06,
      right: height * 0.06,
      bottom: height * 0.06,
      child: DecoratedBox(
        key: const Key('info-overlay'),
        decoration: BoxDecoration(
          color: const Color(0xD9000000),
          borderRadius: BorderRadius.circular(height * 0.015),
        ),
        child: Padding(
          padding: EdgeInsets.all(height * 0.03),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                name,
                key: const Key('info-name'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: style,
              ),
              if (place.isNotEmpty)
                Text(place, key: const Key('info-place'), style: small),
              SizedBox(height: height * 0.015),
              LinearProgressIndicator(
                key: const Key('info-progress'),
                value: progress,
                minHeight: height * 0.008,
              ),
              SizedBox(height: height * 0.008),
              Text(
                duration == null || duration <= 0
                    ? clockText(position)
                    : '${clockText(position)} / ${clockText(duration)}',
                key: const Key('info-time'),
                style: small,
              ),
              if (!online)
                Padding(
                  padding: EdgeInsets.only(top: height * 0.01),
                  child: Text(
                    cached
                        ? 'The Pi is not reachable. Playing from the TV cache.'
                        : 'The Pi is not reachable.',
                    key: const Key('info-offline'),
                    style: small.copyWith(color: const Color(0xFFFFB74D)),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
