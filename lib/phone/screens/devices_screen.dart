import 'package:flutter/material.dart';
import 'package:hub_core/hub_core.dart';

import '../phone_controller.dart';
import 'ui.dart';

/// Shows [message] in a brief floating snackbar.
void showBrief(BuildContext context, String message) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  messenger
    ?..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(milliseconds: 1800),
      ),
    );
}

/// Asks for a new name for this phone. The reason a name is refused shows
/// under the field.
Future<void> showRenameDialog(
  BuildContext context,
  PhoneController controller,
) async {
  final saved = await showDialog<bool>(
    context: context,
    builder: (_) => _RenameDialog(controller: controller),
  );
  if (saved == true && context.mounted) showBrief(context, 'Name saved');
}

class _RenameDialog extends StatefulWidget {
  const _RenameDialog({required this.controller});

  final PhoneController controller;

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final TextEditingController _text = TextEditingController(
    text: widget.controller.me?.name ?? '',
  );
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final r = await widget.controller.renameThisPhone(_text.text);
    if (!mounted) return;
    if (r.ok) {
      Navigator.of(context).pop(true);
    } else {
      setState(() {
        _busy = false;
        _error = r.message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Name this phone'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Other phones and the TV see this name.'),
          const SizedBox(height: 16),
          TextField(
            key: const Key('rename-field'),
            controller: _text,
            autofocus: true,
            maxLength: PhoneController.maxDeviceNameLength,
            textInputAction: TextInputAction.done,
            textCapitalization: TextCapitalization.words,
            onSubmitted: (_) => _save(),
            onChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
            decoration: InputDecoration(
              labelText: 'Phone name',
              errorText: _error,
              border: const OutlineInputBorder(),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('rename-save'),
          onPressed: _busy ? null : _save,
          child: const Text('Save'),
        ),
      ],
    );
  }
}

/// Asks before removing [device]; the owner only. Shows the outcome.
Future<void> confirmForgetDevice(
  BuildContext context,
  PhoneController controller,
  DeviceInfo device,
) async {
  final yes = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('Remove ${device.name}?'),
      content: const Text(
        'This phone stops controlling the TV. It can pair again by scanning '
        'the QR code on the TV.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('forget-device-confirm'),
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Remove'),
        ),
      ],
    ),
  );
  if (yes != true) return;
  final r = await controller.forgetDevice(device.id);
  if (context.mounted) {
    showBrief(context, r.ok ? '${device.name} removed' : r.message!);
  }
}

/// Asks before removing every phone, this one included (owner only).
Future<void> confirmForgetAllPhones(
  BuildContext context,
  PhoneController controller,
) async {
  final yes = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Forget all phones?'),
      content: const Text(
        'Every phone, including this one, stops controlling the TV. The next '
        'phone that pairs becomes the owner. Photos and videos stay on the '
        'Pi.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('forget-all-confirm'),
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(ctx).colorScheme.error,
            foregroundColor: Theme.of(ctx).colorScheme.onError,
          ),
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Forget all'),
        ),
      ],
    ),
  );
  if (yes != true) return;
  final r = await controller.forgetAllPhones();
  if (!r.ok && context.mounted) showBrief(context, r.message!);
}

/// One paired device: online light, name, role, and its actions.
class DeviceTile extends StatelessWidget {
  const DeviceTile({
    super.key,
    required this.device,
    required this.isMe,
    this.large = false,
    this.onRename,
    this.onRemove,
  });

  final DeviceInfo device;
  final bool isMe;

  /// Taller row for the Devices screen.
  final bool large;
  final VoidCallback? onRename;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final icon = device.isDisplay ? Icons.tv : Icons.smartphone;
    final state = device.online ? 'Online' : 'Offline';
    return ConstrainedBox(
      constraints: BoxConstraints(minHeight: large ? 72 : 56),
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: large ? 8 : 4),
        child: Row(
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                CircleAvatar(
                  radius: large ? 24 : 20,
                  backgroundColor: theme.colorScheme.secondaryContainer,
                  foregroundColor: theme.colorScheme.onSecondaryContainer,
                  child: Icon(icon),
                ),
                Positioned(
                  right: -1,
                  bottom: -1,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: theme.colorScheme.surfaceContainerLow,
                        width: 2,
                      ),
                    ),
                    child: StatusDot(
                      key: Key('dot-${device.id}'),
                      on: device.online,
                      size: 12,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    isMe ? '${device.name} (this phone)' : device.name,
                    style: large
                        ? theme.textTheme.titleMedium
                        : theme.textTheme.bodyLarge,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    '${roleLabel(device.role)} · $state',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            if (onRename != null)
              IconButton(
                key: const Key('rename-phone'),
                tooltip: 'Rename this phone',
                onPressed: onRename,
                icon: const Icon(Icons.edit_outlined),
              ),
            if (onRemove != null)
              IconButton(
                key: Key('remove-${device.id}'),
                tooltip: 'Remove ${device.name}',
                onPressed: onRemove,
                icon: Icon(
                  Icons.person_remove_outlined,
                  color: theme.colorScheme.error,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The paired devices as a list of [DeviceTile]s, with rename for this phone
/// and, for the owner, remove for the others.
class DeviceList extends StatelessWidget {
  const DeviceList({super.key, required this.controller, this.large = false});

  final PhoneController controller;
  final bool large;

  @override
  Widget build(BuildContext context) {
    final me = controller.me;
    final devices = controller.devices;
    if (devices.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Text('No devices yet.'),
      );
    }
    final canRemove = controller.canChangeSettings;
    return Column(
      children: [
        for (var i = 0; i < devices.length; i++) ...[
          if (i > 0) const Divider(height: 1),
          DeviceTile(
            device: devices[i],
            isMe: devices[i].id == me?.id,
            large: large,
            onRename: devices[i].id == me?.id && controller.isLinked
                ? () => showRenameDialog(context, controller)
                : null,
            onRemove:
                canRemove &&
                    devices[i].role == DeviceRole.controller &&
                    devices[i].id != me?.id
                ? () => confirmForgetDevice(context, controller, devices[i])
                : null,
          ),
        ],
      ],
    );
  }
}

/// The Devices destination: every paired phone and the TV.
class DevicesScreen extends StatelessWidget {
  const DevicesScreen({super.key, required this.controller});

  final PhoneController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final theme = Theme.of(context);
        final phones = controller.devices.where((d) => !d.isDisplay).length;
        return PageList(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 8, 4, 16),
              child: Text(
                phones == 1 ? '1 phone paired' : '$phones phones paired',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            Card(
              elevation: 0,
              color: theme.colorScheme.surfaceContainerLow,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
                side: BorderSide(color: theme.colorScheme.outlineVariant),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: DeviceList(controller: controller, large: true),
              ),
            ),
            if (!controller.canChangeSettings && controller.isLinked)
              const Padding(
                padding: EdgeInsets.fromLTRB(4, 16, 4, 0),
                child: Text('Only the owner can remove phones.'),
              ),
          ],
        );
      },
    );
  }
}
