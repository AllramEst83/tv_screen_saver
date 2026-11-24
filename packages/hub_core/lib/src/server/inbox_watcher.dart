import 'dart:async';
import 'dart:io';

import 'library_store.dart';

/// Watches a folder (the Samba share `inbox`) and imports each file once it
/// has stopped changing.
///
/// A file is imported when its size and modification time have not changed
/// for [stableFor]. Success: the file is moved into the library (a scaled-down
/// copy for a large image). Refusal: the file moves to `rejected/` with a
/// `<name>.txt` that says why; nothing is deleted. Sub-folders, dot files and
/// the `rejected` folder are ignored.
class InboxWatcher {
  InboxWatcher({
    required this.dir,
    required this.library,
    this.stableFor = const Duration(seconds: 10),
    this.pollEvery = const Duration(seconds: 5),
    DateTime Function()? now,
    void Function(String message)? log,
  }) : _now = now ?? DateTime.now,
       _log = log ?? ((m) => stderr.writeln('tvsaver inbox: $m'));

  final String dir;
  final LibraryStore library;
  final Duration stableFor;
  final Duration pollEvery;
  final DateTime Function() _now;
  final void Function(String) _log;

  final Map<String, _Seen> _seen = {};
  Timer? _timer;
  Future<void> _running = Future.value();
  bool _stopped = false;

  /// Files imported and files rejected since start (tests, logs).
  int imported = 0;
  int rejected = 0;

  Future<void> start() async {
    _stopped = false;
    await Directory(dir).create(recursive: true);
    _timer?.cancel();
    _timer = Timer.periodic(pollEvery, (_) => pollNow());
    unawaited(pollNow());
  }

  Future<void> stop() async {
    _stopped = true;
    _timer?.cancel();
    _timer = null;
    await _running;
  }

  /// Looks at the folder once. Calls never overlap.
  Future<void> pollNow() {
    _running = _running.then((_) => _poll()).catchError((Object e) {
      _log('poll failed: $e');
    });
    return _running;
  }

  Future<void> _poll() async {
    if (_stopped) return;
    final d = Directory(dir);
    if (!await d.exists()) return;
    final present = <String>{};
    await for (final e in d.list(followLinks: false)) {
      if (_stopped) return;
      if (e is! File) continue;
      final name = e.uri.pathSegments.where((s) => s.isNotEmpty).last;
      if (name.startsWith('.') || name.startsWith('~')) continue;
      present.add(e.path);
      final FileStat st;
      try {
        st = await e.stat();
      } on FileSystemException {
        continue;
      }
      final seen = _seen[e.path];
      if (seen == null ||
          seen.size != st.size ||
          seen.modified != st.modified) {
        _seen[e.path] = _Seen(st.size, st.modified, _now());
        continue;
      }
      if (_now().difference(seen.since) < stableFor) continue;
      await _import(e, name);
      _seen.remove(e.path);
    }
    _seen.removeWhere((path, _) => !present.contains(path));
  }

  Future<void> _import(File file, String name) async {
    try {
      await library.importFile(file.path, name: name);
      imported++;
    } on ImportRefused catch (r) {
      await _reject(file, name, r.reason);
    } catch (e) {
      // Not the file's fault (disk, database): leave it for the next poll.
      _log('could not import $name: $e');
      _seen[file.path] = _Seen(
        -1,
        DateTime.fromMillisecondsSinceEpoch(0),
        _now(),
      );
    }
  }

  Future<void> _reject(File file, String name, String reason) async {
    final out = Directory('$dir/rejected');
    await out.create(recursive: true);
    var target = name;
    var n = 1;
    while (await File('${out.path}/$target').exists() ||
        await File('${out.path}/$target.txt').exists()) {
      final dot = name.lastIndexOf('.');
      target = dot > 0
          ? '${name.substring(0, dot)} (${++n})${name.substring(dot)}'
          : '$name (${++n})';
    }
    try {
      await file.rename('${out.path}/$target');
    } on FileSystemException {
      await file.copy('${out.path}/$target');
      await file.delete();
    }
    await File('${out.path}/$target.txt').writeAsString('$reason\n');
    rejected++;
    _log('rejected $name: $reason');
  }
}

class _Seen {
  _Seen(this.size, this.modified, this.since);

  final int size;
  final DateTime modified;
  final DateTime since;
}
