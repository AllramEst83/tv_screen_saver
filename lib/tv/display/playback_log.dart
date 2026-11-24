import 'dart:io';

/// A small CSV of what happened to the picture: lifecycle changes, each new
/// item and a heartbeat every few minutes. After a long run it shows whether
/// anything interrupted playback and when. Lines are
/// `time,event,item,state,detail`; the file stays below [maxBytes] (the older
/// half goes to `<file>.1`). Nothing in it is private: no tokens, no names
/// of phones, only item ids.
abstract interface class PlaybackLog {
  void event(String name, {String? item, String? state, String? detail});
}

/// [PlaybackLog] that does nothing (tests, and a TV without storage).
class NoPlaybackLog implements PlaybackLog {
  const NoPlaybackLog();

  @override
  void event(String name, {String? item, String? state, String? detail}) {}
}

/// [PlaybackLog] on a file. Failures to write are swallowed: a log must never
/// stop the picture.
class FilePlaybackLog implements PlaybackLog {
  FilePlaybackLog(
    this.file, {
    this.maxBytes = 512 * 1024,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final File file;
  final int maxBytes;
  final DateTime Function() _now;

  @override
  void event(String name, {String? item, String? state, String? detail}) {
    try {
      file.parent.createSync(recursive: true);
      if (file.existsSync() && file.lengthSync() > maxBytes) {
        file.renameSync('${file.path}.1');
      }
      final line = [
        _now().toIso8601String(),
        name,
        _clean(item),
        _clean(state),
        _clean(detail),
      ].join(',');
      file.writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
    } catch (_) {
      // Never stop the picture for a log.
    }
  }

  static String _clean(String? v) =>
      (v ?? '').replaceAll(RegExp(r'[,\r\n]'), ' ');
}
