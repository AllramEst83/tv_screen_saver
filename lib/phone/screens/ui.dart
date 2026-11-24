import 'package:flutter/material.dart';
import 'package:hub_core/hub_core.dart';

/// Shared building blocks of the phone app: spacing, cards, formats.

/// Space between two groups on a page.
const double kGap = 16;

/// Widest a page grows on a tablet.
const double kPageMaxWidth = 640;

String roleLabel(DeviceRole role) => switch (role) {
  DeviceRole.owner => 'Owner',
  DeviceRole.controller => 'Controller',
  DeviceRole.display => 'TV',
};

/// `90 GB`, `2.5 GB`, `512 MB` (decimal units, like the Pi's storage cap).
String formatBytes(int bytes) {
  if (bytes < 1000 * 1000) return '${(bytes / 1000).round()} KB';
  if (bytes < 1000 * 1000 * 1000) {
    return '${(bytes / 1e6).round()} MB';
  }
  return '${trimNumber(bytes / 1e9, 1)} GB';
}

/// `90`, `2.5`, `12.3`: no trailing `.0`.
String trimNumber(num value, int decimals) {
  final s = value.toStringAsFixed(decimals);
  if (!s.contains('.')) return s;
  return s.replaceFirst(RegExp(r'\.?0+$'), '');
}

/// A scrolling page: centered, at most [kPageMaxWidth] wide, 16 dp gutters.
class PageList extends StatelessWidget {
  const PageList({super.key, required this.children, this.controller});

  final List<Widget> children;
  final ScrollController? controller;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final side = box.maxWidth > kPageMaxWidth + 32
            ? (box.maxWidth - kPageMaxWidth) / 2
            : 16.0;
        return ListView(
          controller: controller,
          padding: EdgeInsets.fromLTRB(side, 8, side, 32),
          children: children,
        );
      },
    );
  }
}

/// A titled card that groups related options.
class PaneCard extends StatelessWidget {
  const PaneCard({
    super.key,
    required this.title,
    required this.icon,
    required this.children,
    this.intro,
  });

  final String title;
  final IconData icon;

  /// One line that says what this pane is about.
  final String? intro;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: kGap),
      elevation: 0,
      color: theme.colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: theme.colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Semantics(
              header: true,
              child: Row(
                children: [
                  Icon(icon, color: theme.colorScheme.primary),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(title, style: theme.textTheme.titleMedium),
                  ),
                ],
              ),
            ),
            if (intro != null) ...[
              const SizedBox(height: 4),
              Text(
                intro!,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: 8),
            ...children,
          ],
        ),
      ),
    );
  }
}

/// A label with its value on one row; wraps under the label when narrow.
class InfoRow extends StatelessWidget {
  const InfoRow({super.key, required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 16,
        runSpacing: 2,
        children: [
          Text(
            label,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          Text(value, style: theme.textTheme.bodyLarge),
        ],
      ),
    );
  }
}

/// A small round status light with a text equivalent for screen readers.
class StatusDot extends StatelessWidget {
  const StatusDot({super.key, required this.on, this.size = 10, this.color});

  final bool on;
  final double size;

  /// Overrides the default green and grey.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      label: on ? 'online' : 'offline',
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color:
              color ?? (on ? Colors.green : theme.colorScheme.outlineVariant),
        ),
      ),
    );
  }
}
