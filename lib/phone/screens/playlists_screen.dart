import 'package:flutter/material.dart';

import '../phone_controller.dart';
import 'devices_screen.dart' show showBrief;
import 'ui.dart';

/// The stored playlists: play, edit, delete, create. Works with the TV off;
/// only playing needs it.
class PlaylistsScreen extends StatelessWidget {
  const PlaylistsScreen({super.key, required this.controller});

  final PhoneController controller;

  Future<void> _edit(BuildContext context, [Map<String, Object?>? playlist]) =>
      Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) =>
              PlaylistEditor(controller: controller, playlist: playlist),
        ),
      );

  Future<void> _play(BuildContext context, Map<String, Object?> p) async {
    await controller.playPlaylist('${p['id']}');
    if (!context.mounted) return;
    if (controller.tvNotConnected) {
      showBrief(context, 'The TV is not connected');
    } else if (controller.playerError != null) {
      showBrief(context, controller.playerError!);
    }
  }

  Future<void> _delete(BuildContext context, Map<String, Object?> p) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete "${p['name']}"?'),
        content: const Text('The pictures and videos stay in the library.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Keep it'),
          ),
          FilledButton(
            key: const Key('confirm-delete-playlist'),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (yes != true || !context.mounted) return;
    final r = await controller.deletePlaylist('${p['id']}');
    if (!r.ok && context.mounted) showBrief(context, r.message!);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final list = controller.playlists;
        final linked = controller.isLinked;
        return PageList(
          children: [
            PaneCard(
              title: 'Playlists',
              icon: Icons.queue_music_outlined,
              intro:
                  'Choose what plays and in which order. You can edit '
                  'playlists even when the TV is off.',
              children: [
                const SizedBox(height: 4),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    key: const Key('new-playlist'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(56),
                    ),
                    onPressed: linked ? () => _edit(context) : null,
                    icon: const Icon(Icons.playlist_add),
                    label: const Text('New playlist'),
                  ),
                ),
                const SizedBox(height: 8),
                if (!controller.hasPlaylists)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Text('Loading…'),
                  )
                else if (list.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      'No playlists yet. Make one from the pictures and '
                      'videos in your library.',
                    ),
                  )
                else
                  for (final p in list)
                    _PlaylistRow(
                      playlist: p,
                      isOwner: controller.isOwner,
                      linked: linked,
                      onPlay: () => _play(context, p),
                      onEdit: () => _edit(context, p),
                      onDelete: () => _delete(context, p),
                    ),
              ],
            ),
          ],
        );
      },
    );
  }
}

class _PlaylistRow extends StatelessWidget {
  const _PlaylistRow({
    required this.playlist,
    required this.isOwner,
    required this.linked,
    required this.onPlay,
    required this.onEdit,
    required this.onDelete,
  });

  final Map<String, Object?> playlist;
  final bool isOwner;
  final bool linked;
  final VoidCallback onPlay;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final items = (playlist['items'] as List?)?.length ?? 0;
    final notes = [
      '$items ${items == 1 ? 'item' : 'items'}',
      if (playlist['shuffle'] == true) 'shuffled',
    ].join(' · ');
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 64),
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              key: Key('playlist-${playlist['id']}'),
              onTap: linked ? onEdit : null,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${playlist['name']}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyLarge,
                    ),
                    Text(
                      notes,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          IconButton.filledTonal(
            key: Key('play-${playlist['id']}'),
            tooltip: 'Play',
            iconSize: 28,
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            onPressed: linked && items > 0 ? onPlay : null,
            icon: const Icon(Icons.play_arrow),
          ),
          if (isOwner)
            IconButton(
              key: Key('delete-${playlist['id']}'),
              tooltip: 'Delete',
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
              onPressed: linked ? onDelete : null,
              icon: const Icon(Icons.delete_outline),
            ),
        ],
      ),
    );
  }
}

/// Create or change one playlist.
class PlaylistEditor extends StatefulWidget {
  const PlaylistEditor({super.key, required this.controller, this.playlist});

  final PhoneController controller;
  final Map<String, Object?>? playlist;

  @override
  State<PlaylistEditor> createState() => _PlaylistEditorState();
}

class _PlaylistEditorState extends State<PlaylistEditor> {
  late final TextEditingController _name = TextEditingController(
    text: '${widget.playlist?['name'] ?? ''}',
  );
  late List<String> _items = [
    for (final i in (widget.playlist?['items'] as List?) ?? const []) '$i',
  ];
  late bool _shuffle = widget.playlist?['shuffle'] == true;
  late bool _muted = widget.playlist?['muted'] == true;
  late bool _kenBurns = widget.playlist?['kenBurns'] == true;
  late int? _seconds = widget.playlist?['imageSeconds'] as int?;
  late String? _transition = widget.playlist?['transition'] as String?;
  String? _nameError;
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _nameError = null;
      _error = null;
    });
    final r = await widget.controller.savePlaylist({
      'name': _name.text,
      'items': _items,
      'shuffle': _shuffle,
      'muted': _muted,
      'kenBurns': _kenBurns,
      'imageSeconds': _seconds,
      'transition': _transition,
    }, id: widget.playlist?['id'] as String?);
    if (!mounted) return;
    if (r.ok) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _busy = false;
      if (r.field == 'name') {
        _nameError = r.message;
      } else {
        _error = r.message;
      }
    });
  }

  Future<void> _addItems() async {
    final chosen = await showModalBottomSheet<List<String>>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _ItemPicker(
        library: widget.controller.libraryItems,
        already: _items.toSet(),
      ),
    );
    if (chosen == null || chosen.isEmpty) return;
    setState(() => _items = [..._items, ...chosen]);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = widget.controller;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.playlist == null ? 'New playlist' : 'Edit playlist'),
        actions: [
          TextButton(
            key: const Key('save-playlist'),
            onPressed: _busy ? null : _save,
            child: const Text('Save'),
          ),
        ],
      ),
      body: PageList(
        children: [
          TextField(
            key: const Key('playlist-name'),
            controller: _name,
            maxLength: 60,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(
              labelText: 'Name',
              errorText: _nameError,
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          PaneCard(
            title: 'What plays',
            icon: Icons.photo_library_outlined,
            intro: 'Hold and drag to change the order.',
            children: [
              if (_items.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Text('Nothing added yet.'),
                )
              else
                ReorderableListView(
                  key: const Key('playlist-items'),
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  onReorderItem: (from, to) => setState(() {
                    _items.insert(to, _items.removeAt(from));
                  }),
                  children: [
                    for (final id in _items)
                      ListTile(
                        key: ValueKey(id),
                        minVerticalPadding: 8,
                        title: Text(c.nameOfItem(id)),
                        trailing: IconButton(
                          tooltip: 'Remove',
                          constraints: const BoxConstraints(
                            minWidth: 48,
                            minHeight: 48,
                          ),
                          onPressed: () => setState(() => _items.remove(id)),
                          icon: const Icon(Icons.close),
                        ),
                      ),
                  ],
                ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                key: const Key('add-items'),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                ),
                onPressed: _addItems,
                icon: const Icon(Icons.add),
                label: const Text('Add from library'),
              ),
            ],
          ),
          PaneCard(
            title: 'How it plays',
            icon: Icons.tune,
            children: [
              SwitchListTile(
                key: const Key('opt-shuffle'),
                contentPadding: EdgeInsets.zero,
                title: const Text('Shuffle'),
                subtitle: const Text('Mix up the order'),
                value: _shuffle,
                onChanged: (v) => setState(() => _shuffle = v),
              ),
              SwitchListTile(
                key: const Key('opt-muted'),
                contentPadding: EdgeInsets.zero,
                title: const Text('Play videos without sound'),
                value: _muted,
                onChanged: (v) => setState(() => _muted = v),
              ),
              SwitchListTile(
                key: const Key('opt-kenburns'),
                contentPadding: EdgeInsets.zero,
                title: const Text('Slow zoom on photos'),
                subtitle: const Text('Off keeps photos perfectly sharp'),
                value: _kenBurns,
                onChanged: (v) => setState(() => _kenBurns = v),
              ),
              DropdownButtonFormField<int?>(
                key: const Key('opt-seconds'),
                isExpanded: true,
                initialValue: _seconds,
                decoration: const InputDecoration(labelText: 'Time per photo'),
                items: [
                  DropdownMenuItem(
                    value: null,
                    child: Text(
                      'Use the Settings value'
                      '${c.settingInt('imageSeconds') == null ? '' : ' (${c.settingInt('imageSeconds')} s)'}',
                    ),
                  ),
                  for (final s in const [5, 10, 15, 30, 60])
                    DropdownMenuItem(value: s, child: Text('$s seconds')),
                ],
                onChanged: (v) => setState(() => _seconds = v),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String?>(
                key: const Key('opt-transition'),
                isExpanded: true,
                initialValue: _transition,
                decoration: const InputDecoration(labelText: 'Change between'),
                items: const [
                  DropdownMenuItem(
                    value: null,
                    child: Text('Use the Settings value'),
                  ),
                  DropdownMenuItem(value: 'crossfade', child: Text('Fade')),
                  DropdownMenuItem(value: 'cut', child: Text('Straight cut')),
                ],
                onChanged: (v) => setState(() => _transition = v),
              ),
            ],
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                _error!,
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ),
        ],
      ),
    );
  }
}

class _ItemPicker extends StatefulWidget {
  const _ItemPicker({required this.library, required this.already});

  final List<Map<String, Object?>> library;
  final Set<String> already;

  @override
  State<_ItemPicker> createState() => _ItemPickerState();
}

class _ItemPickerState extends State<_ItemPicker> {
  final List<String> _chosen = [];

  @override
  Widget build(BuildContext context) {
    final available = [
      for (final i in widget.library)
        if (!widget.already.contains(i['id'])) i,
    ];
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.8,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'Choose from the library',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            Flexible(
              child: available.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text('Everything in the library is already here.'),
                    )
                  : ListView(
                      shrinkWrap: true,
                      children: [
                        for (final i in available)
                          CheckboxListTile(
                            key: Key('pick-${i['id']}'),
                            value: _chosen.contains(i['id']),
                            title: Text('${i['name']}'),
                            subtitle: Text(
                              i['kind'] == 'video' ? 'Video' : 'Photo',
                            ),
                            onChanged: (v) => setState(() {
                              final id = '${i['id']}';
                              v == true ? _chosen.add(id) : _chosen.remove(id);
                            }),
                          ),
                      ],
                    ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  key: const Key('picked-done'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(52),
                  ),
                  onPressed: () => Navigator.pop(context, _chosen),
                  child: Text(
                    _chosen.isEmpty ? 'Cancel' : 'Add ${_chosen.length}',
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
