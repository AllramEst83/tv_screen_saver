import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'spike_log.dart';
import 'spike_native.dart';
import 'spike_player.dart';

/// The adb command that puts the clips where the app looks for them.
const pushHint = 'bash tool/video/push_clips.sh 192.168.0.24:5555';

/// Lists the video files in a directory, sorted by name. Injected for tests.
typedef SpikeClipLister = Future<List<String>> Function(String dir);

Future<List<String>> listClipFiles(String dir) async {
  final d = Directory(dir);
  if (!await d.exists()) return [];
  final files = [
    await for (final e in d.list())
      if (e is File && e.path.toLowerCase().endsWith('.mp4')) e.path,
  ]..sort();
  return files;
}

/// Remote-driven video test screen (story 1-2). Up/Down moves, OK acts:
/// the first row toggles the view (texture / platform-view / Media3 surface),
/// the second the loop strategy, then one row per clip pushed with
/// `tool/video/push_clips.sh`. Playing a clip logs `VideoSpike:` lines.
class SpikeScreen extends StatefulWidget {
  const SpikeScreen({
    super.key,
    this.native = const ChannelSpikeNative(),
    this.lister = listClipFiles,
    this.log = spikeLog,
    this.controllerFactory = defaultSpikeController,
    this.media3View,
  });

  final SpikeNative native;
  final SpikeClipLister lister;
  final void Function(String line) log;
  final SpikeControllerFactory controllerFactory;

  /// Passed to [SpikePlayer.media3View]; injected for tests.
  final Widget Function(void Function(int id) onCreated)? media3View;

  @override
  State<SpikeScreen> createState() => _SpikeScreenState();
}

class _SpikeScreenState extends State<SpikeScreen> {
  List<String>? _clips;
  String? _dir;
  int _selected = 0;
  SpikeView _view = SpikeView.platformView;
  SpikeLoop _loop = SpikeLoop.repeatOne;
  String? _playing;

  static const _settingRows = 2;

  /// Playlist looping only exists in the Media3 view, so it forces that view.
  SpikeView get _effectiveView =>
      _loop == SpikeLoop.playlist ? SpikeView.media3 : _view;

  @override
  void initState() {
    super.initState();
    unawaited(_scan());
  }

  Future<void> _scan() async {
    final dir = await widget.native.spikeDir();
    final clips = dir == null ? <String>[] : await widget.lister(dir);
    if (!mounted) return;
    setState(() {
      _dir = dir;
      _clips = clips;
    });
  }

  int get _rowCount => _settingRows + (_clips?.length ?? 0);

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowDown) {
      setState(() => _selected = (_selected + 1).clamp(0, _rowCount - 1));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      setState(() => _selected = (_selected - 1).clamp(0, _rowCount - 1));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.arrowRight) {
      _activate();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft && _selected < _settingRows) {
      _activate(reverse: true);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _activate({bool reverse = false}) {
    setState(() {
      if (_selected == 0) {
        final v = SpikeView.values;
        _view = v[(_view.index + (reverse ? v.length - 1 : 1)) % v.length];
      } else if (_selected == 1) {
        final l = SpikeLoop.values;
        _loop = l[(_loop.index + 1) % l.length];
      } else if (_selected - _settingRows < (_clips?.length ?? 0)) {
        _playing = _clips![_selected - _settingRows];
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final playing = _playing;
    if (playing != null) {
      return SpikePlayer(
        key: ValueKey('$playing|${_effectiveView.name}|${_loop.name}'),
        path: playing,
        view: _effectiveView,
        loop: _loop,
        native: widget.native,
        log: widget.log,
        controllerFactory: widget.controllerFactory,
        media3View: widget.media3View,
        onExit: () {
          if (mounted) setState(() => _playing = null);
        },
      );
    }
    return Focus(autofocus: true, onKeyEvent: _onKey, child: _list(context));
  }

  Widget _list(BuildContext context) {
    final height = MediaQuery.sizeOf(context).height;
    final clips = _clips;
    final body = TextStyle(color: Colors.white, fontSize: height * 0.045);
    final note = TextStyle(
      color: const Color(0xFFD0D0D0),
      fontSize: height * 0.035,
    );

    final rows = <String>[
      'View: ${_view.label}${_loop == SpikeLoop.playlist ? '  (playlist loop uses ${SpikeView.media3.label})' : ''}',
      'Loop: ${_loop.label}',
      if (clips != null) ...clips.map((c) => c.split(RegExp(r'[\\/]')).last),
    ];

    return ColoredBox(
      color: Colors.black,
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: height * 0.1,
          vertical: height * 0.08,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Video spike',
              style: body.copyWith(
                fontSize: height * 0.07,
                fontWeight: FontWeight.w600,
              ),
            ),
            SizedBox(height: height * 0.02),
            Text(
              'Up/Down: move   OK: change or play   Back: leave',
              style: note,
            ),
            SizedBox(height: height * 0.03),
            if (clips == null)
              Text('Looking for clips…', style: body)
            else ...[
              for (var i = 0; i < rows.length; i++)
                _row(i, rows[i], i == _selected, body),
              if (clips.isEmpty) ...[
                SizedBox(height: height * 0.03),
                Text('No clips on the TV yet.', style: body),
                Text('Push them from the PC (Git Bash):', style: note),
                Text(pushHint, style: note),
                if (_dir != null) Text('into $_dir', style: note),
              ],
            ],
          ],
        ),
      ),
    );
  }

  Widget _row(int index, String text, bool selected, TextStyle style) =>
      Container(
        key: ValueKey('row-$index'),
        color: selected ? const Color(0xFF2A4D8F) : Colors.transparent,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Text(text, style: style),
      );
}
