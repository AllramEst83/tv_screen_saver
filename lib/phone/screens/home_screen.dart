import 'package:flutter/material.dart';

import '../phone_controller.dart';
import 'now_playing_card.dart';
import 'ui.dart';

/// The Now playing page: the hero card and a short status of the TV and the
/// phones. The app's frame (app bar, drawer, banner) is [AppShell].
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key, required this.controller});

  final PhoneController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final theme = Theme.of(context);
        final phones = controller.devices.where((d) => !d.isDisplay).length;
        final tvOk = controller.isLinked && !controller.tvNotConnected;
        return PageList(
          children: [
            NowPlayingCard(controller: controller),
            const SizedBox(height: kGap),
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: _StatTile(
                      key: const Key('tile-tv'),
                      icon: tvOk ? Icons.tv : Icons.tv_off,
                      label: 'TV',
                      value: !controller.isLinked
                          ? 'Unknown'
                          : tvOk
                          ? 'Connected'
                          : 'Not connected',
                      warn: controller.isLinked && !tvOk,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _StatTile(
                      key: const Key('tile-phones'),
                      icon: Icons.smartphone,
                      label: 'Phones',
                      value: phones == 1 ? '1 paired' : '$phones paired',
                    ),
                  ),
                ],
              ),
            ),
            if (controller.me != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 16, 4, 0),
                child: Text(
                  controller.me!.isOwner
                      ? 'This phone is the owner.'
                      : 'This phone is a controller. Only the owner can '
                            'change settings.',
                  key: const Key('my-role'),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    this.warn = false,
  });

  final IconData icon;
  final String label;
  final String value;
  final bool warn;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: warn ? scheme.error : scheme.primary),
            const SizedBox(height: 12),
            Text(
              label,
              style: theme.textTheme.labelMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            Text(
              value,
              style: theme.textTheme.titleMedium?.copyWith(
                color: warn ? scheme.error : null,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
