import 'package:flutter/material.dart';

import '../phone_controller.dart';
import 'about_screen.dart';
import 'devices_screen.dart';
import 'home_screen.dart';
import 'settings_screen.dart';
import 'ui.dart';

/// One entry of the drawer. Library and Playlists (stories 4-3 and 4-4) are
/// added to [buildDestinations] and nothing else.
class ShellDestination {
  const ShellDestination({
    required this.id,
    required this.label,
    required this.icon,
    required this.selectedIcon,
    required this.builder,
  });

  final String id;
  final String label;
  final IconData icon;
  final IconData selectedIcon;
  final Widget Function(BuildContext context, PhoneController controller)
  builder;
}

/// The screens that exist today, in drawer order.
List<ShellDestination> buildDestinations({VersionLoader? versionLoader}) => [
  ShellDestination(
    id: 'now-playing',
    label: 'Now playing',
    icon: Icons.play_circle_outline,
    selectedIcon: Icons.play_circle,
    builder: (_, c) => HomeScreen(controller: c),
  ),
  ShellDestination(
    id: 'devices',
    label: 'Devices',
    icon: Icons.devices_outlined,
    selectedIcon: Icons.devices,
    builder: (_, c) => DevicesScreen(controller: c),
  ),
  ShellDestination(
    id: 'settings',
    label: 'Settings',
    icon: Icons.settings_outlined,
    selectedIcon: Icons.settings,
    builder: (_, c) =>
        SettingsScreen(controller: c, versionLoader: versionLoader),
  ),
  ShellDestination(
    id: 'about',
    label: 'About',
    icon: Icons.info_outline,
    selectedIcon: Icons.info,
    builder: (_, c) => AboutScreen(controller: c, versionLoader: versionLoader),
  ),
];

/// The connected phone app: app bar, navigation drawer, a status banner when
/// the Pi is away, and the current destination.
class AppShell extends StatefulWidget {
  const AppShell({
    super.key,
    required this.controller,
    this.destinations,
    this.versionLoader,
  });

  final PhoneController controller;

  /// Replaces the default destinations (tests).
  final List<ShellDestination>? destinations;
  final VersionLoader? versionLoader;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  late final List<ShellDestination> _destinations =
      widget.destinations ??
      buildDestinations(versionLoader: widget.versionLoader);
  int _index = 0;
  bool _asking = false;

  PhoneController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    controller.addListener(_checkApproval);
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkApproval());
  }

  @override
  void dispose() {
    controller.removeListener(_checkApproval);
    super.dispose();
  }

  /// A TV waits for approval: ask. The dialog closes by itself when the
  /// request ends (approved on another phone, timed out, the TV left).
  void _checkApproval() {
    final pending = controller.pendingApproval;
    if (pending == null || _asking || !mounted) return;
    _asking = true;
    showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _ApprovalDialog(controller: controller),
    ).then((_) => _asking = false);
  }

  @override
  Widget build(BuildContext context) {
    final dest = _destinations[_index];
    return PopScope(
      // Back from another page goes to Now playing before it leaves the app.
      canPop: _index == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(() => _index = 0);
      },
      child: Scaffold(
        appBar: AppBar(
          title: ListenableBuilder(
            listenable: controller,
            builder: (context, _) => Text(
              _index == 0 ? (controller.hub.hubName ?? 'TV Saver') : dest.label,
              key: const Key('home-title'),
            ),
          ),
          centerTitle: false,
        ),
        drawer: _ShellDrawer(
          controller: controller,
          destinations: _destinations,
          selected: _index,
          onSelect: (i) {
            Navigator.of(context).pop();
            if (i != _index) setState(() => _index = i);
          },
        ),
        body: Column(
          children: [
            ListenableBuilder(
              listenable: controller,
              builder: (context, _) => _StatusBanner(controller: controller),
            ),
            Expanded(
              child: SafeArea(
                top: false,
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 220),
                  switchInCurve: Curves.easeOut,
                  transitionBuilder: (child, animation) => FadeTransition(
                    opacity: animation,
                    child: SlideTransition(
                      position: Tween(
                        begin: const Offset(0, .02),
                        end: Offset.zero,
                      ).animate(animation),
                      child: child,
                    ),
                  ),
                  child: KeyedSubtree(
                    key: ValueKey(dest.id),
                    child: dest.builder(context, controller),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// "Reconnecting…" or "Can't reach the Pi" under the app bar; gone when the
/// link is up.
class _StatusBanner extends StatelessWidget {
  const _StatusBanner({required this.controller});

  final PhoneController controller;

  @override
  Widget build(BuildContext context) {
    final status = controller.linkStatus;
    final theme = Theme.of(context);
    final Widget? banner = switch (status) {
      LinkStatus.reconnecting => _bar(
        context,
        key: const Key('banner-reconnecting'),
        color: theme.colorScheme.tertiaryContainer,
        onColor: theme.colorScheme.onTertiaryContainer,
        leading: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(
            strokeWidth: 2.5,
            color: theme.colorScheme.onTertiaryContainer,
          ),
        ),
        text: 'Reconnecting…',
      ),
      LinkStatus.offline || LinkStatus.serverDown => _bar(
        context,
        key: Key(
          status == LinkStatus.offline ? 'banner-offline' : 'banner-server',
        ),
        color: theme.colorScheme.errorContainer,
        onColor: theme.colorScheme.onErrorContainer,
        leading: Icon(
          Icons.cloud_off_outlined,
          size: 20,
          color: theme.colorScheme.onErrorContainer,
        ),
        text: status == LinkStatus.offline
            ? "Can't reach the Pi"
            : 'The TV Saver server is not running on the Pi',
        action: TextButton(
          key: const Key('banner-retry'),
          style: TextButton.styleFrom(
            foregroundColor: theme.colorScheme.onErrorContainer,
            minimumSize: const Size(48, 48),
          ),
          onPressed: controller.retry,
          child: const Text('Retry'),
        ),
      ),
      _ => null,
    };
    return AnimatedSize(
      duration: const Duration(milliseconds: 200),
      alignment: Alignment.topCenter,
      child: banner ?? const SizedBox(width: double.infinity),
    );
  }

  Widget _bar(
    BuildContext context, {
    required Key key,
    required Color color,
    required Color onColor,
    required Widget leading,
    required String text,
    Widget? action,
  }) {
    return Semantics(
      liveRegion: true,
      child: Container(
        key: key,
        width: double.infinity,
        color: color,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 40),
          child: Row(
            children: [
              leading,
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  text,
                  style: Theme.of(context).textTheme.labelLarge
                      ?.copyWith(color: onColor),
                ),
              ),
              ?action,
            ],
          ),
        ),
      ),
    );
  }
}

class _ShellDrawer extends StatelessWidget {
  const _ShellDrawer({
    required this.controller,
    required this.destinations,
    required this.selected,
    required this.onSelect,
  });

  final PhoneController controller;
  final List<ShellDestination> destinations;
  final int selected;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final scheme = Theme.of(context).colorScheme;
        final shape = RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(28),
        );
        return Drawer(
          child: SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.only(bottom: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _DrawerHeader(controller: controller),
                  for (var i = 0; i < destinations.length; i++)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 2,
                      ),
                      child: ListTile(
                        key: Key('nav-${destinations[i].id}'),
                        minTileHeight: 56,
                        shape: shape,
                        selected: i == selected,
                        selectedTileColor: scheme.secondaryContainer,
                        selectedColor: scheme.onSecondaryContainer,
                        leading: Icon(
                          i == selected
                              ? destinations[i].selectedIcon
                              : destinations[i].icon,
                        ),
                        title: Text(destinations[i].label),
                        onTap: () => onSelect(i),
                      ),
                    ),
                  const Padding(
                    padding: EdgeInsets.fromLTRB(28, 8, 28, 8),
                    child: Divider(height: 1),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: ListTile(
                      key: const Key('drawer-close'),
                      minTileHeight: 56,
                      shape: shape,
                      leading: const Icon(Icons.power_settings_new),
                      title: const Text('Close app'),
                      onTap: () {
                        Navigator.of(context).pop();
                        controller.closeApp();
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _DrawerHeader extends StatelessWidget {
  const _DrawerHeader({required this.controller});

  final PhoneController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final status = controller.linkStatus;
    final (text, color) = switch (status) {
      LinkStatus.connected => ('Connected', Colors.green),
      LinkStatus.tvOff => ('TV off', scheme.tertiary),
      LinkStatus.reconnecting => ('Reconnecting…', scheme.tertiary),
      LinkStatus.offline => ('Offline', scheme.error),
      LinkStatus.serverDown => ('Server not running', scheme.error),
    };
    final me = controller.me;
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 24, 24, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: scheme.primaryContainer,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Icon(Icons.tv, color: scheme.onPrimaryContainer),
          ),
          const SizedBox(height: 16),
          Text(
            controller.hub.hubName ?? 'TV Saver',
            key: const Key('drawer-pi-name'),
            style: theme.textTheme.titleLarge,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(shape: BoxShape.circle, color: color),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  text,
                  key: const Key('drawer-status'),
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            ],
          ),
          if (me != null) ...[
            const SizedBox(height: 2),
            Text(
              'This phone: ${roleLabel(me.role)}',
              key: const Key('drawer-role'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ApprovalDialog extends StatelessWidget {
  const _ApprovalDialog({required this.controller});

  final PhoneController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (ctx, _) {
        final pending = controller.pendingApproval;
        if (pending == null) {
          // The request ended: close this dialog.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (ctx.mounted && Navigator.of(ctx).canPop()) {
              Navigator.of(ctx).pop();
            }
          });
          return const SizedBox.shrink();
        }
        return AlertDialog(
          title: const Text('Approve this TV?'),
          content: Text('"${pending.name}" wants to join as the TV display.'),
          actions: [
            TextButton(
              key: const Key('approve-deny'),
              onPressed: () {
                controller.answerApproval(false);
                Navigator.of(ctx).pop();
              },
              child: const Text('Deny'),
            ),
            FilledButton(
              key: const Key('approve-yes'),
              onPressed: () {
                controller.answerApproval(true);
                Navigator.of(ctx).pop();
              },
              child: const Text('Approve'),
            ),
          ],
        );
      },
    );
  }
}
