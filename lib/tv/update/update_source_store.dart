import 'dart:io';

/// Where the TV remembers the update address (the desktop's
/// `http://<pc>:8099/update.json`).
abstract interface class UpdateSourceStore {
  Future<String?> updateSource();
  Future<void> setUpdateSource(String? url);
}

/// [UpdateSourceStore] in one small text file in the app's own directory.
class FileUpdateSourceStore implements UpdateSourceStore {
  FileUpdateSourceStore(this.file);

  final File file;

  @override
  Future<String?> updateSource() async {
    try {
      if (!await file.exists()) return null;
      final text = (await file.readAsString()).trim();
      return text.isEmpty ? null : text;
    } on FileSystemException {
      return null;
    }
  }

  @override
  Future<void> setUpdateSource(String? url) async {
    if (url == null || url.isEmpty) {
      if (await file.exists()) await file.delete();
      return;
    }
    await file.parent.create(recursive: true);
    await file.writeAsString(url);
  }
}

/// [UpdateSourceStore] in memory (tests).
class MemoryUpdateSourceStore implements UpdateSourceStore {
  MemoryUpdateSourceStore([this._url]);

  String? _url;

  @override
  Future<String?> updateSource() async => _url;

  @override
  Future<void> setUpdateSource(String? url) async => _url = url;
}
