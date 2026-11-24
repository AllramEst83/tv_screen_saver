import 'package:flutter/material.dart';
import 'package:hub_core/hub_core.dart';

import '../phone_controller.dart';
import 'now_playing_card.dart';

/// Connected: the Pi's name, this phone's role and the paired devices.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.controller});

  final PhoneController controller;

  static String roleLabel(DeviceRole role) => switch (role) {
    DeviceRole.owner => 'Owner',
    DeviceRole.controller => 'Controller',
    DeviceRole.display => 'TV',
  };

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
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
    final hub = controller.hub;
    final me = controller.me;
    final devices = controller.devices;
    return Scaffold(
      appBar: AppBar(
        title: Text(hub.hubName ?? 'TV Saver', key: const Key('home-title')),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            NowPlayingCard(controller: controller),
            const SizedBox(height: 8),
            if (me != null)
              ListTile(
                key: const Key('my-role'),
                leading: const Icon(Icons.phone_android),
                title: Text('You: ${HomeScreen.roleLabel(me.role)}'),
                subtitle: Text(me.name),
              ),
            const Divider(),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                'Paired devices',
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            for (final d in devices)
              ListTile(
                key: Key('device-${d.id}'),
                leading: Semantics(
                  label: d.online ? 'online' : 'offline',
                  child: Icon(
                    Icons.circle,
                    key: Key('dot-${d.id}'),
                    size: 12,
                    color: d.online ? Colors.green : Colors.grey,
                  ),
                ),
                title: Text(d.id == me?.id ? '${d.name} (this phone)' : d.name),
                subtitle: Text(HomeScreen.roleLabel(d.role)),
              ),
            const SizedBox(height: 24),
            OutlinedButton(
              key: const Key('forget-pi'),
              onPressed: () => _confirmForget(context),
              child: const Text('Forget this Pi'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmForget(BuildContext context) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Forget this Pi?'),
        content: const Text(
          'This phone will stop controlling it. Other phones and the TV '
          'are not affected, and the Pi keeps the device record of this phone. '
          'If you are the only owner, you may need `tvsaver admin '
          'reset-pairings` on the Pi or "Forget all phones" on the TV to '
          'become owner again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            key: const Key('forget-confirm'),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Forget'),
          ),
        ],
      ),
    );
    if (yes != true) return;
    final ok = await controller.forgetThisPi();
    if (!ok && context.mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('Could not forget this Pi.')),
      );
    }
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
