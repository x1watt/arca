// A profile's library: the collections it created, each a folder on disk
// with its files described and hashed (docs/architecture.md, 5 and 10).
//
// This is the first, local-only form. Collections live in one circle, the
// built-in Arca Commons, until circles can be created.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart' as c;

import '../crypto/hex.dart';
import 'sidecars.dart';

/// The catch-all circle every profile belongs to from the start: open to
/// everyone, with no admin, where the first collections are made.
abstract final class Commons {
  static const id = 'commons';
  static const name = 'Arca Commons';
  static const description =
      'The open circle every Arca user starts in. Anyone can create collections here '
      'and share them with everyone.';
}

class LibraryFile {
  LibraryFile({
    required this.path,
    required this.size,
    required this.sha256,
    required this.sha1,
    required this.mime,
    required this.addedAt,
    this.title = '',
    this.description = '',
    this.tags = const [],
    List<Map<String, Object?>>? layers,
  }) : layers = layers ?? [];

  /// Path inside the collection folder, with forward slashes.
  final String path;
  final int size;
  final String sha256;
  final String sha1;
  final String mime;
  final int addedAt;
  String title;
  String description;
  List<String> tags;

  /// Text layers kept beside the file (subtitles for now), as recorded in
  /// its manifest: file name, language, and who or what made them.
  List<Map<String, Object?>> layers;

  String get name => path.split('/').last;

  /// The manifest written beside the file (sidecars.dart).
  Map<String, Object?> manifest() => {
    'format': manifestFormat,
    'file': name,
    'size': size,
    'sha256': sha256,
    if (sha1.isNotEmpty) 'sha1': sha1,
    'mime': mime,
    'title': title,
    'description': description,
    'tags': tags,
    'added': DateTime.fromMillisecondsSinceEpoch(addedAt * 1000, isUtc: true).toIso8601String(),
    'layers': layers,
  };

  Map<String, Object?> toJson() => {
    'path': path,
    'size': size,
    'sha256': sha256,
    'sha1': sha1,
    'mime': mime,
    'addedAt': addedAt,
    'title': title,
    'description': description,
    'tags': tags,
    if (layers.isNotEmpty) 'layers': layers,
  };

  factory LibraryFile.fromJson(Map<String, dynamic> m) => LibraryFile(
    path: m['path'] as String,
    size: m['size'] as int,
    sha256: m['sha256'] as String,
    sha1: m['sha1'] as String? ?? '',
    mime: m['mime'] as String,
    addedAt: m['addedAt'] as int,
    title: m['title'] as String? ?? '',
    description: m['description'] as String? ?? '',
    tags: (m['tags'] as List?)?.cast<String>().toList() ?? const [],
    layers: [for (final l in m['layers'] as List? ?? const []) (l as Map).cast<String, Object?>()],
  );
}

class Collection {
  Collection({
    required this.id,
    required this.name,
    required this.folder,
    required this.createdAt,
    this.description = '',
    this.circle = Commons.id,
    List<LibraryFile>? files,
  }) : files = files ?? [];

  final String id;
  String name;
  String description;
  final String circle;

  /// Absolute folder that holds the collection's files.
  final String folder;
  final int createdAt;
  final List<LibraryFile> files;

  int get size => files.fold(0, (n, f) => n + f.size);

  Map<String, Object> toJson() => {
    'id': id,
    'name': name,
    'description': description,
    'circle': circle,
    'folder': folder,
    'createdAt': createdAt,
    'files': [for (final f in files) f.toJson()],
  };

  factory Collection.fromJson(Map<String, dynamic> m) => Collection(
    id: m['id'] as String,
    name: m['name'] as String,
    description: m['description'] as String? ?? '',
    circle: m['circle'] as String? ?? Commons.id,
    folder: m['folder'] as String,
    createdAt: m['createdAt'] as int,
    files: [for (final f in m['files'] as List) LibraryFile.fromJson(f as Map<String, dynamic>)],
  );
}

class LibraryException implements Exception {
  LibraryException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// SHA-256 and SHA-1 of a file, read once in chunks.
Future<(String, String, int)> hashFile(File f) async {
  final out256 = _DigestSink(), out1 = _DigestSink();
  final s256 = c.sha256.startChunkedConversion(out256);
  final s1 = c.sha1.startChunkedConversion(out1);
  var size = 0;
  await for (final chunk in f.openRead()) {
    s256.add(chunk);
    s1.add(chunk);
    size += chunk.length;
  }
  s256.close();
  s1.close();
  return (out256.value.toString(), out1.value.toString(), size);
}

class _DigestSink implements Sink<c.Digest> {
  late c.Digest value;
  @override
  void add(c.Digest data) => value = data;
  @override
  void close() {}
}

/// The media type of a file, from its first bytes where they are telling,
/// otherwise from its extension.
Future<String> detectMime(File f) async {
  final head = <int>[];
  await for (final chunk in f.openRead(0, 16)) {
    head.addAll(chunk);
  }
  bool starts(List<int> sig, [int at = 0]) =>
      head.length >= at + sig.length && List.generate(sig.length, (i) => i).every((i) => head[at + i] == sig[i]);
  if (starts([0x25, 0x50, 0x44, 0x46])) return 'application/pdf';
  if (starts([0x89, 0x50, 0x4E, 0x47])) return 'image/png';
  if (starts([0xFF, 0xD8, 0xFF])) return 'image/jpeg';
  if (starts([0x47, 0x49, 0x46, 0x38])) return 'image/gif';
  if (starts([0x52, 0x49, 0x46, 0x46]) && starts([0x57, 0x45, 0x42, 0x50], 8)) return 'image/webp';
  if (starts([0x4F, 0x67, 0x67, 0x53])) return 'audio/ogg';
  if (starts([0x66, 0x4C, 0x61, 0x43])) return 'audio/flac';
  if (starts([0x49, 0x44, 0x33])) return 'audio/mpeg';
  if (starts([0x1A, 0x45, 0xDF, 0xA3])) {
    return f.path.toLowerCase().endsWith('.webm') ? 'video/webm' : 'video/x-matroska';
  }
  if (starts([0x66, 0x74, 0x79, 0x70], 4)) return 'video/mp4';
  final ext = f.path.contains('.') ? f.path.split('.').last.toLowerCase() : '';
  return _byExtension[ext] ?? (starts([0x50, 0x4B, 0x03, 0x04]) ? 'application/zip' : 'application/octet-stream');
}

const _byExtension = {
  'txt': 'text/plain',
  'md': 'text/markdown',
  'html': 'text/html',
  'csv': 'text/csv',
  'json': 'application/json',
  'epub': 'application/epub+zip',
  'zip': 'application/zip',
  'tar': 'application/x-tar',
  'gz': 'application/gzip',
  'mp3': 'audio/mpeg',
  'opus': 'audio/opus',
  'wav': 'audio/wav',
  'mp4': 'video/mp4',
  'mkv': 'video/x-matroska',
  'webm': 'video/webm',
  'tif': 'image/tiff',
  'tiff': 'image/tiff',
  'svg': 'image/svg+xml',
  'gpx': 'application/gpx+xml',
  'kml': 'application/vnd.google-earth.kml+xml',
  'pbf': 'application/x-protobuf',
  'doc': 'application/msword',
  'docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'odt': 'application/vnd.oasis.opendocument.text',
};

/// Collections of one profile, kept in `collections.json` in its folder.
class Library {
  Library._(this._file, this._collections, this.sidecars);

  final File _file;
  final List<Collection> _collections;

  /// Manifests and subtitles beside the files; shared with the core so the
  /// folder listings it keeps are the same ones.
  final Sidecars sidecars;

  static Future<Library> open(File file, {Sidecars? sidecars}) async {
    final list = <Collection>[];
    if (await file.exists()) {
      final m = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      list.addAll([for (final c in m['collections'] as List) Collection.fromJson(c as Map<String, dynamic>)]);
    }
    return Library._(file, list, sidecars ?? Sidecars());
  }

  List<Collection> get collections => List.unmodifiable(_collections);

  Collection byId(String id) =>
      _collections.firstWhere((c) => c.id == id, orElse: () => throw LibraryException('No collection $id'));

  /// Creates a collection. With [folder] it adopts that folder and every file
  /// already in it; otherwise it makes a new folder under [baseFolder].
  Future<Collection> create({
    required String name,
    String description = '',
    String? folder,
    required String baseFolder,
    void Function(int done, int total)? progress,
  }) async {
    final clean = name.trim();
    if (clean.isEmpty) throw LibraryException('Give the collection a name.');
    final dir = Directory(folder ?? '$baseFolder/${_safeName(clean)}');
    if (folder != null && !await dir.exists()) throw LibraryException('That folder does not exist.');
    if (_collections.any((c) => c.folder == dir.absolute.path)) {
      throw LibraryException('That folder is already a collection.');
    }
    await dir.create(recursive: true);
    final col = Collection(
      id: toHex(List.generate(8, (_) => Random.secure().nextInt(256))),
      name: clean,
      description: description.trim(),
      folder: dir.absolute.path,
      createdAt: _now(),
    );
    if (folder != null) {
      final existing = await dir
          .list(recursive: true, followLinks: false)
          .where((e) => e is File && !_hidden(e.path, dir.path) && !_isSidecar(e.path))
          .cast<File>()
          .toList();
      var i = 0;
      for (final f in existing) {
        col.files.add(await _describe(col, f));
        progress?.call(++i, existing.length);
      }
    }
    _collections.add(col);
    await _save();
    for (final f in col.files) {
      await writeManifest(col, f);
    }
    return col;
  }

  /// Copies [paths] (files, or folders with their contents) into the
  /// collection and describes them. Returns how many files were added.
  Future<int> addFiles(String collectionId, List<String> paths, {void Function(int done, int total)? progress}) async {
    final col = byId(collectionId);
    final jobs = <(File, String)>[];
    for (final p in paths) {
      final type = await FileSystemEntity.type(p);
      if (type == FileSystemEntityType.file) {
        jobs.add((File(p), p.split(Platform.pathSeparator).last));
      } else if (type == FileSystemEntityType.directory) {
        final root = Directory(p);
        final top = p.split(Platform.pathSeparator).where((s) => s.isNotEmpty).last;
        await for (final e in root.list(recursive: true, followLinks: false)) {
          // Sidecars come along with the file they belong to.
          if (e is File && !_hidden(e.path, root.path) && !_isSidecar(e.path)) {
            jobs.add((e, '$top/${e.path.substring(root.path.length + 1).replaceAll('\\', '/')}'));
          }
        }
      }
    }
    var added = 0;
    final fresh = <LibraryFile>[];
    for (final (src, rel) in jobs) {
      final target = File('${col.folder}/${_uniqueRel(col, rel)}');
      if (src.absolute.path != target.absolute.path) {
        await target.parent.create(recursive: true);
        await src.copy(target.path);
        await _copySidecars(src.absolute.path, target.absolute.path);
      }
      final f = await _describe(col, target);
      col.files.add(f);
      fresh.add(f);
      added++;
      progress?.call(added, jobs.length);
    }
    await _save();
    for (final f in fresh) {
      await writeManifest(col, f);
    }
    return added;
  }

  /// Hashes and types [f]; takes its title, description, tags and layers
  /// from the manifest beside it when that manifest is about these bytes.
  Future<LibraryFile> _describe(Collection col, File f) async {
    final (sha256, sha1, size) = await hashFile(f);
    final rel = f.absolute.path.substring(col.folder.length + 1).replaceAll('\\', '/');
    final name = rel.split('/').last;
    final m = sidecars.readManifest(f.absolute.path, sha256: sha256);
    final subtitleNames = {for (final s in sidecars.subtitlesOf(f.absolute.path)) s.name};
    return LibraryFile(
      path: rel,
      size: size,
      sha256: sha256,
      sha1: sha1,
      mime: await detectMime(f),
      addedAt: _now(),
      title: m?['title'] as String? ?? (name.contains('.') ? name.substring(0, name.lastIndexOf('.')) : name),
      description: m?['description'] as String? ?? '',
      tags: (m?['tags'] as List?)?.whereType<String>().toList() ?? const [],
      layers: [
        for (final l in (m?['layers'] as List?) ?? const [])
          if (l is Map && subtitleNames.contains(l['file'])) l.cast<String, Object?>(),
      ],
    );
  }

  /// Copies the manifest and subtitles beside [src] to sit beside [target],
  /// renamed to follow it.
  Future<void> _copySidecars(String src, String target) async {
    final srcBase = sidecars.baseOf(src);
    for (final path in sidecars.allOf(src)) {
      final suffix = path.substring(srcBase.length);
      await File(path).copy('${sidecars.baseOf(target)}$suffix');
    }
    sidecars.changed(target);
  }

  bool _isSidecar(String path) => sidecars.belongsToSibling(path.replaceAll('\\', '/'));

  /// Rewrites the manifest beside [f] from what the library knows.
  Future<void> writeManifest(Collection col, LibraryFile f) =>
      sidecars.writeManifest('${col.folder}/${f.path}', f.manifest());

  /// Saves the library and the file's manifest after [f] changed.
  Future<void> saveFile(Collection col, LibraryFile f) async {
    await _save();
    await writeManifest(col, f);
  }

  String _uniqueRel(Collection col, String rel) {
    var candidate = rel;
    var n = 2;
    while (col.files.any((f) => f.path == candidate) || File('${col.folder}/$candidate').existsSync()) {
      final dot = rel.lastIndexOf('.');
      candidate = dot > rel.lastIndexOf('/') + 1 ? '${rel.substring(0, dot)} ($n)${rel.substring(dot)}' : '$rel ($n)';
      n++;
    }
    return candidate;
  }

  Future<void> updateCollection(String id, {String? name, String? description}) async {
    final col = byId(id);
    if (name != null && name.trim().isNotEmpty) col.name = name.trim();
    if (description != null) col.description = description.trim();
    await _save();
  }

  Future<void> updateFile(
    String collectionId,
    String path, {
    String? title,
    String? description,
    List<String>? tags,
  }) async {
    final f = byId(
      collectionId,
    ).files.firstWhere((f) => f.path == path, orElse: () => throw LibraryException('No such file in the collection'));
    if (title != null) f.title = title.trim();
    if (description != null) f.description = description.trim();
    if (tags != null) {
      f.tags = [
        for (final t in tags)
          if (t.trim().isNotEmpty) t.trim().toLowerCase().replaceAll(RegExp(r'\s+'), '-'),
      ].take(32).toList();
    }
    await saveFile(byId(collectionId), f);
  }

  /// Removes a file from the collection; with [deleteFromDisk] also deletes it.
  Future<void> removeFile(String collectionId, String path, {bool deleteFromDisk = false}) async {
    final col = byId(collectionId);
    col.files.removeWhere((f) => f.path == path);
    if (deleteFromDisk) {
      final abs = '${col.folder}/$path';
      for (final p in [...sidecars.allOf(abs), abs]) {
        final f = File(p);
        if (await f.exists()) await f.delete();
      }
      sidecars.changed(abs);
    }
    await _save();
  }

  /// Stops tracking a collection. Its folder and files stay on disk.
  Future<void> removeCollection(String id) async {
    _collections.removeWhere((c) => c.id == id);
    await _save();
  }

  Future<void> _save() async {
    final tmp = File('${_file.path}.tmp');
    await tmp.writeAsString(
      const JsonEncoder.withIndent(' ').convert({
        'collections': [for (final c in _collections) c.toJson()],
      }),
      flush: true,
    );
    await tmp.rename(_file.path);
  }

  static bool _hidden(String path, String root) =>
      path.substring(root.length).split(Platform.pathSeparator).any((s) => s.startsWith('.'));

  static String _safeName(String name) =>
      name.replaceAll(RegExp(r'[/\\:*?"<>|\x00-\x1f]'), '_').replaceAll(RegExp(r'^[. ]+|[. ]+$'), '');

  static int _now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;
}
