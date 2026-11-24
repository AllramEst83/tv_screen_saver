import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../phone_controller.dart';
import '../upload/uploader.dart';
import 'devices_screen.dart' show showBrief;
import 'ui.dart';

/// Lets the user choose photos and videos to add. Returns none when
/// cancelled.
typedef PickPictures = Future<List<UploadSource>> Function();

/// Opens the system picker and hands back the original files (no resizing,
/// no re-compression: the phone prepares them itself).
Future<List<UploadSource>> pickPicturesFromGallery() async {
  final files = await ImagePicker().pickMultipleMedia();
  return [for (final f in files) _PickedSource(f)];
}

class _PickedSource extends UploadSource {
  _PickedSource(this.picked);

  final XFile picked;

  @override
  String get name => picked.name;

  @override
  Future<Uint8List> read() => picked.readAsBytes();

  @override
  File get file => File(picked.path);
}

/// What is stored on the Pi, the storage bar and the upload queue.
class LibraryScreen extends StatelessWidget {
  const LibraryScreen({super.key, required this.controller, this.pick});

  final PhoneController controller;
  final PickPictures? pick;

  Future<void> _add(BuildContext context) async {
    final sources = await (pick ?? pickPicturesFromGallery)();
    if (sources.isEmpty) return;
    controller.uploader.add(sources);
  }

  Future<void> _delete(BuildContext context, Map<String, Object?> item) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete "${item['name']}"?'),
        content: const Text(
          'It is removed from the Pi and from every playlist. This cannot '
          'be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Keep it'),
          ),
          FilledButton(
            key: const Key('confirm-delete-item'),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (yes != true || !context.mounted) return;
    final r = await controller.deleteLibraryItem('${item['id']}');
    if (!context.mounted) return;
    showBrief(context, r.ok ? 'Deleted' : r.message!);
  }

  @override
  Widget build(BuildContext context) {
    final uploader = controller.uploader;
    return ListenableBuilder(
      listenable: Listenable.merge([controller, uploader]),
      builder: (context, _) {
        final theme = Theme.of(context);
        final items = controller.libraryItems;
        final canAdd = controller.canUpload;
        return PageList(
          children: [
            PaneCard(
              title: 'Add to the library',
              icon: Icons.add_photo_alternate_outlined,
              intro:
                  'Photos are made ready on this phone and sent to the Pi: '
                  'where a photo was taken is never sent. Videos are sent '
                  'as they are.',
              children: [
                const SizedBox(height: 4),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    key: const Key('add-photos'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(56),
                    ),
                    onPressed: canAdd ? () => _add(context) : null,
                    icon: const Icon(Icons.add_photo_alternate),
                    label: const Text('Add photos or videos'),
                  ),
                ),
                if (!canAdd)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      'Connect to the Pi to add photos and videos.',
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                _Storage(controller: controller),
              ],
            ),
            if (uploader.items.isNotEmpty)
              PaneCard(
                title: 'Sending',
                icon: Icons.upload_outlined,
                children: [
                  for (final item in uploader.items)
                    _UploadRow(item: item, uploader: uploader),
                  if (!uploader.busy)
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        key: const Key('clear-finished'),
                        onPressed: uploader.clearFinished,
                        child: const Text('Clear finished'),
                      ),
                    ),
                ],
              ),
            PaneCard(
              title: 'On the Pi',
              icon: Icons.photo_library_outlined,
              children: [
                if (!controller.hasLibrary)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Text('Loading…'),
                  )
                else if (items.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      'Nothing here yet. Tap Add photos or videos to send '
                      'your first one.',
                    ),
                  )
                else
                  for (final item in items)
                    _ItemRow(
                      item: item,
                      canDelete: controller.isOwner && controller.isLinked,
                      onDelete: () => _delete(context, item),
                    ),
              ],
            ),
          ],
        );
      },
    );
  }
}

class _Storage extends StatelessWidget {
  const _Storage({required this.controller});

  final PhoneController controller;

  @override
  Widget build(BuildContext context) {
    final cap = controller.storageCapBytes;
    if (!controller.hasLibrary || cap <= 0) return const SizedBox.shrink();
    final used = controller.storageUsedBytes;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LinearProgressIndicator(
            value: (used / cap).clamp(0.0, 1.0),
            minHeight: 8,
            borderRadius: BorderRadius.circular(4),
          ),
          const SizedBox(height: 6),
          Text('${formatBytes(used)} of ${formatBytes(cap)} used'),
        ],
      ),
    );
  }
}

class _UploadRow extends StatelessWidget {
  const _UploadRow({required this.item, required this.uploader});

  final UploadItem item;
  final ImageUploader uploader;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: item,
      builder: (context, _) {
        final theme = Theme.of(context);
        final (text, color) = switch (item.status) {
          UploadStatus.waiting => ('Waiting', null),
          UploadStatus.preparing => ('Getting ready…', null),
          UploadStatus.uploading => (
            'Sending ${(item.progress * 100).round()} %',
            null,
          ),
          UploadStatus.done => (
            item.alreadyThere ? ImageUploader.duplicateMessage : 'Added',
            null,
          ),
          UploadStatus.failed => (
            item.error ?? ImageUploader.failedMessage,
            theme.colorScheme.error,
          ),
        };
        return ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 56),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyLarge,
                      ),
                      Text(
                        text,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: color ?? theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      if (item.status == UploadStatus.uploading ||
                          item.status == UploadStatus.preparing)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: LinearProgressIndicator(
                            value: item.status == UploadStatus.uploading
                                ? item.progress
                                : null,
                          ),
                        ),
                    ],
                  ),
                ),
                if (item.status == UploadStatus.failed)
                  TextButton(
                    key: Key('retry-${item.name}'),
                    onPressed: () => uploader.retry(item),
                    child: const Text('Try again'),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _ItemRow extends StatelessWidget {
  const _ItemRow({
    required this.item,
    required this.canDelete,
    required this.onDelete,
  });

  final Map<String, Object?> item;
  final bool canDelete;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isVideo = item['kind'] == 'video';
    final bytes = item['bytes'];
    final state = item['state'];
    final reason = item['stateReason'];
    final notes = <String>[
      isVideo ? 'Video' : 'Photo',
      if (bytes is int) formatBytes(bytes),
      if (state == 'unsupported' && reason is String && reason.isNotEmpty)
        reason
      else if (state == 'unsupported')
        'The TV cannot play this',
      if (isVideo && item['cacheRequired'] == true) 'Plays after caching',
    ];
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 56),
      child: Row(
        children: [
          Icon(isVideo ? Icons.movie_outlined : Icons.image_outlined),
          const SizedBox(width: 12),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${item['name']}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyLarge,
                  ),
                  Text(
                    notes.join(' · '),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (canDelete)
            IconButton(
              key: Key('delete-item-${item['id']}'),
              tooltip: 'Delete',
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
              onPressed: onDelete,
              icon: const Icon(Icons.delete_outline),
            ),
        ],
      ),
    );
  }
}
