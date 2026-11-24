import 'package:flutter/material.dart';
import 'package:hub_core/hub_core.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../phone_controller.dart';
import 'ui.dart';

/// Reads the app version, e.g. `0.1.0 (1)`. Replaced in tests.
typedef VersionLoader = Future<String> Function();

Future<String> _packageVersion() async {
  final info = await PackageInfo.fromPlatform();
  return '${info.version} (${info.buildNumber})';
}

/// The About pane: app version, the Pi's name, id and version, TV state.
/// Used on the Settings page and, alone, on the About destination.
class AboutPane extends StatefulWidget {
  const AboutPane({super.key, required this.controller, this.versionLoader});

  final PhoneController controller;
  final VersionLoader? versionLoader;

  @override
  State<AboutPane> createState() => _AboutPaneState();
}

class _AboutPaneState extends State<AboutPane> {
  String? _version;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    String v;
    try {
      v = await (widget.versionLoader ?? _packageVersion)();
    } catch (_) {
      v = 'Unknown';
    }
    if (mounted) setState(() => _version = v);
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final hub = c.hub;
    final tvText = !c.isLinked
        ? 'Unknown'
        : c.tvNotConnected
        ? 'Not connected'
        : 'Connected';
    return PaneCard(
      title: 'About',
      icon: Icons.info_outline,
      children: [
        InfoRow(label: 'App version', value: _version ?? '…'),
        InfoRow(label: 'Pi name', value: hub.hubName ?? 'Unknown'),
        InfoRow(label: 'Pi id', value: hub.hubId ?? 'Unknown'),
        InfoRow(label: 'Pi software', value: 'Protocol $kProtocolVersion'),
        InfoRow(label: 'TV', value: tvText),
      ],
    );
  }
}

/// The About destination.
class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key, required this.controller, this.versionLoader});

  final PhoneController controller;
  final VersionLoader? versionLoader;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => PageList(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Column(
              children: [
                Container(
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(22),
                  ),
                  child: Icon(
                    Icons.tv,
                    size: 36,
                    color: theme.colorScheme.onPrimaryContainer,
                  ),
                ),
                const SizedBox(height: 12),
                Text('TV Saver', style: theme.textTheme.headlineSmall),
                const SizedBox(height: 4),
                Text(
                  'Your photos and videos on the big screen.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          AboutPane(controller: controller, versionLoader: versionLoader),
        ],
      ),
    );
  }
}
