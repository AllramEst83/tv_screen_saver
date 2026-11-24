import 'dart:async';

import 'package:flutter/material.dart';

import '../now_playing.dart';
import '../phone_controller.dart';

/// Now playing and the player controls: play, previous, pause/resume, next,
/// seek 30 s either way and mute. The position runs from the Pi's `startedAt`
/// so it matches what other phones and the TV show.
class NowPlayingCard extends StatefulWidget {
  const NowPlayingCard({super.key, required this.controller});

  final PhoneController controller;

  @override
  State<NowPlayingCard> createState() => _NowPlayingCardState();
}

class _NowPlayingCardState extends State<NowPlayingCard> {
  Timer? _tick;

  PhoneController get _c => widget.controller;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncTimer();
  }

  @override
  void didUpdateWidget(NowPlayingCard old) {
    super.didUpdateWidget(old);
    _syncTimer();
  }

  /// A one-second clock only while something plays.
  void _syncTimer() {
    final want = _c.nowPlaying.isPlaying;
    if (want && _tick == null) {
      _tick = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } else if (!want) {
      _tick?.cancel();
      _tick = null;
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _syncTimer();
    final np = _c.nowPlaying;
    final theme = Theme.of(context);
    final title = np.isIdle ? 'Nothing playing' : np.itemId!;
    final status = np.isIdle
        ? 'Press Play to start the playlist'
        : '${np.isPlaying ? 'Playing' : 'Paused'} · '
              '${formatPosition(_c.positionMs)}'
              '${np.muted ? ' · muted' : ''}';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_c.tvNotConnected)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  key: const Key('tv-not-connected'),
                  children: [
                    Icon(Icons.tv_off, color: theme.colorScheme.error),
                    const SizedBox(width: 8),
                    Text(
                      'TV not connected',
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                  ],
                ),
              ),
            Text(
              title,
              key: const Key('now-playing-title'),
              style: theme.textTheme.titleMedium,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            Text(status, key: const Key('now-playing-status')),
            if (_c.playerError != null)
              Text(
                _c.playerError!,
                key: const Key('player-error'),
                style: TextStyle(color: theme.colorScheme.error),
              ),
            const SizedBox(height: 8),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 4,
              children: [
                if (np.isIdle)
                  FilledButton.icon(
                    key: const Key('player-play'),
                    onPressed: _c.play,
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('Play'),
                  )
                else ...[
                  IconButton(
                    key: const Key('player-back30'),
                    tooltip: 'Back 30 seconds',
                    onPressed: () => _c.seekBy(-30000),
                    icon: const Icon(Icons.replay_30),
                  ),
                  IconButton(
                    key: const Key('player-prev'),
                    tooltip: 'Previous',
                    onPressed: _c.prev,
                    icon: const Icon(Icons.skip_previous),
                  ),
                  IconButton.filled(
                    key: const Key('player-toggle'),
                    tooltip: np.isPlaying ? 'Pause' : 'Resume',
                    onPressed: _c.togglePause,
                    icon: Icon(np.isPlaying ? Icons.pause : Icons.play_arrow),
                  ),
                  IconButton(
                    key: const Key('player-next'),
                    tooltip: 'Next',
                    onPressed: _c.next,
                    icon: const Icon(Icons.skip_next),
                  ),
                  IconButton(
                    key: const Key('player-fwd30'),
                    tooltip: 'Forward 30 seconds',
                    onPressed: () => _c.seekBy(30000),
                    icon: const Icon(Icons.forward_30),
                  ),
                ],
                IconButton(
                  key: const Key('player-mute'),
                  tooltip: np.muted ? 'Unmute' : 'Mute',
                  onPressed: _c.toggleMute,
                  icon: Icon(np.muted ? Icons.volume_off : Icons.volume_up),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
