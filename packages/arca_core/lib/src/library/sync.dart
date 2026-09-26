// Collections of other people this profile keeps a copy of
// (docs/architecture.md, 4.7): where the copy lives and which version of
// each file it holds. Kept in `synced.json` in the profile's folder.

import 'dart:convert';
import 'dart:io';

class SyncedCollection {
  SyncedCollection({required this.owner, required this.collection, required this.folder, Map<String, String>? files})
    : files = files ?? {};

  final String owner;
  final String collection;

  /// Absolute folder holding the copy.
  final String folder;

  /// Path inside the collection to the SHA-256 of the copy held.
  final Map<String, String> files;

  /// Paths the collection listed at the last pass. Only these are removed
  /// from the copy when the collection stops listing them, so a file just
  /// added here is not deleted by a pass that still sees an older index.
  Set<String> listed = {};

  /// Size of the copy after the last pass.
  int heldBytes = 0;
  int? syncedAt;
  String? error;

  // Progress of the running pass, not saved.
  bool running = false;
  int done = 0;
  int total = 0;
  int bytes = 0;
  int totalBytes = 0;

  String get key => '$owner:$collection';

  Map<String, Object?> toJson() => {
    'owner': owner,
    'collection': collection,
    'folder': folder,
    'files': files,
    'listed': listed.toList(),
    'heldBytes': heldBytes,
    'syncedAt': syncedAt,
    'error': error,
  };

  /// For the UI: progress while a pass runs, what is held otherwise.
  Map<String, Object?> state() => {
    ...toJson(),
    'running': running,
    'done': running ? done : files.length,
    'total': running ? total : files.length,
    'bytes': running ? bytes : heldBytes,
    'totalBytes': running ? totalBytes : heldBytes,
  };

  factory SyncedCollection.fromJson(Map m) =>
      SyncedCollection(
          owner: m['owner'] as String,
          collection: m['collection'] as String,
          folder: m['folder'] as String,
          files: (m['files'] as Map? ?? const {}).cast<String, String>(),
        )
        ..listed = {...(m['listed'] as List? ?? const []).cast<String>()}
        ..heldBytes = m['heldBytes'] as int? ?? 0
        ..syncedAt = m['syncedAt'] as int?
        ..error = m['error'] as String?;
}

class SyncStore {
  SyncStore._(this._file, this.items);
  final File _file;
  final List<SyncedCollection> items;

  static Future<SyncStore> open(File f) async {
    final list = <SyncedCollection>[];
    if (await f.exists()) {
      for (final m in jsonDecode(await f.readAsString()) as List) {
        list.add(SyncedCollection.fromJson(m as Map));
      }
    }
    return SyncStore._(f, list);
  }

  SyncedCollection? find(String owner, String collection) =>
      items.where((s) => s.owner == owner && s.collection == collection).firstOrNull;

  // Saves one at a time: two writers sharing the temporary file would
  // make the second rename fail.
  Future<void> _saving = Future.value();

  Future<void> save() => _saving = _saving.then((_) => _write(), onError: (_) => _write());

  Future<void> _write() async {
    final tmp = File('${_file.path}.tmp');
    await tmp.writeAsString(jsonEncode([for (final s in items) s.toJson()]), flush: true);
    await tmp.rename(_file.path);
  }
}
