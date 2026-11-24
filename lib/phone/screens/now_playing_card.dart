import 'dart:async';

import 'package:flutter/material.dart';

import '../now_playing.dart';
import '../phone_controller.dart';

/// The hero card of the Now playing page: what the TV shows, a progress bar
/// and the player controls. The position runs from the Pi's `startedAt` so it
/// matches what other phones and the TV show.
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
  void initState() {
    super.initState();
    _c.addListener(_onController);
    _syncTimer();
  }

  @override
  void didUpdateWidget(NowPlayingCard old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_onController);
      widget.controller.addListener(_onController);
    }
    _syncTimer();
  }

  void _onController() {
    _syncTimer();
    if (mounted) setState(() {});
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
    _c.removeListener(_onController);
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final np = _c.nowPlaying;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final fg = scheme.onPrimaryContainer;
    final offline = _c.displayKnownOffline;
    final position = np.isIdle ? 0 : _c.positionMs;
    final duration = np.isIdle || np.itemId == null
        ? null
        : _c.durationOf(np.itemId!);
    final progress = duration == null || duration <= 0
        ? 0.0
        : (position / duration).clamp(0.0, 1.0);
    final title = np.isIdle ? 'Nothing playing' : _c.nameOfItem(np.itemId!);
    final status = np.isIdle
        ? 'Press Play to start the playlist'
        : '${np.isPlaying ? 'Playing' : 'Paused'} · '
              '${formatPosition(position)}'
              '${np.muted ? ' · muted' : ''}';
    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: scheme.primaryContainer,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 12, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _StateChip(np: np),
                const Spacer(),
                IconButton(
                  key: const Key('player-mute'),
                  tooltip: np.muted ? 'Unmute' : 'Mute',
                  color: fg,
                  onPressed: offline ? null : _c.toggleMute,
                  icon: Icon(np.muted ? Icons.volume_off : Icons.volume_up),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_c.tvNotConnected) _TvOffNotice(fg: fg),
                  Text(
                    title,
                    key: const Key('now-playing-title'),
                    style: theme.textTheme.headlineSmall?.copyWith(color: fg),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    status,
                    key: const Key('now-playing-status'),
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: fg.withValues(alpha: .8),
                    ),
                  ),
                  if (_c.playerError != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        _c.playerError!,
                        key: const Key('player-error'),
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: scheme.error,
                        ),
                      ),
                    ),
                  const SizedBox(height: 20),
                  Semantics(
                    label: 'Progress',
                    value: duration == null
                        ? null
                        : '${(progress * 100).round()} percent',
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        key: const Key('now-playing-progress'),
                        value: progress,
                        minHeight: 6,
                        color: scheme.primary,
                        backgroundColor: fg.withValues(alpha: .15),
                      ),
                    ),
                  ),
                  if (duration != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            formatPosition(position),
                            style: theme.textTheme.labelMedium?.copyWith(
                              color: fg.withValues(alpha: .8),
                            ),
                          ),
                          Text(
                            formatPosition(duration),
                            style: theme.textTheme.labelMedium?.copyWith(
                              color: fg.withValues(alpha: .8),
                            ),
                          ),
                        ],
                      ),
                    ),
                  const SizedBox(height: 16),
                  if (np.isIdle)
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        key: const Key('player-play'),
                        style: FilledButton.styleFrom(
                          minimumSize: const Size.fromHeight(56),
                        ),
                        onPressed: offline ? null : _c.play,
                        icon: const Icon(Icons.play_arrow, size: 28),
                        label: const Text('Play'),
                      ),
                    )
                  else
                    _Controls(controller: _c, np: np, enabled: !offline),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Playing, Paused or Ready, as a small pill.
class _StateChip extends StatelessWidget {
  const _StateChip({required this.np});

  final NowPlaying np;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (label, icon) = np.isIdle
        ? ('Ready', Icons.tv_outlined)
        : np.isPlaying
        ? ('Playing', Icons.graphic_eq)
        : ('Paused', Icons.pause_circle_outline);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.onPrimaryContainer.withValues(alpha: .1),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: scheme.onPrimaryContainer),
            const SizedBox(width: 6),
            Text(
              label,
              style: Theme.of(context).textTheme.labelLarge
                  ?.copyWith(color: scheme.onPrimaryContainer),
            ),
          ],
        ),
      ),
    );
  }
}

class _TvOffNotice extends StatelessWidget {
  const _TvOffNotice({required this.fg});

  final Color fg;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.colorScheme.surface.withValues(alpha: .7),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            key: const Key('tv-not-connected'),
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.tv_off, color: theme.colorScheme.error),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'TV not connected',
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: theme.colorScheme.error,
                      ),
                    ),
                    Text(
                      'Turn the TV on and open TV Saver. The controls work '
                      'again as soon as it is back.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurface,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Controls extends StatelessWidget {
  const _Controls({
    required this.controller,
    required this.np,
    required this.enabled,
  });

  final PhoneController controller;
  final NowPlaying np;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final scheme = Theme.of(context).colorScheme;
    final fg = scheme.onPrimaryContainer;
    return FittedBox(
      fit: BoxFit.scaleDown,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            key: const Key('player-back30'),
            tooltip: 'Back 30 seconds',
            color: fg,
            onPressed: enabled ? () => c.seekBy(-30000) : null,
            icon: const Icon(Icons.replay_30),
          ),
          const SizedBox(width: 4),
          IconButton.filledTonal(
            key: const Key('player-prev'),
            tooltip: 'Previous',
            iconSize: 30,
            padding: const EdgeInsets.all(13),
            onPressed: enabled ? c.prev : null,
            icon: const Icon(Icons.skip_previous),
          ),
          const SizedBox(width: 8),
          IconButton.filled(
            key: const Key('player-toggle'),
            tooltip: np.isPlaying ? 'Pause' : 'Resume',
            iconSize: 40,
            padding: const EdgeInsets.all(16),
            onPressed: enabled ? c.togglePause : null,
            icon: Icon(np.isPlaying ? Icons.pause : Icons.play_arrow),
          ),
          const SizedBox(width: 8),
          IconButton.filledTonal(
            key: const Key('player-next'),
            tooltip: 'Next',
            iconSize: 30,
            padding: const EdgeInsets.all(13),
            onPressed: enabled ? c.next : null,
            icon: const Icon(Icons.skip_next),
          ),
          const SizedBox(width: 4),
          IconButton(
            key: const Key('player-fwd30'),
            tooltip: 'Forward 30 seconds',
            color: fg,
            onPressed: enabled ? () => c.seekBy(30000) : null,
            icon: const Icon(Icons.forward_30),
          ),
        ],
      ),
    );
  }
}
