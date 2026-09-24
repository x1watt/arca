// Files that travel beside a collection file, named after it, so a folder
// copied anywhere keeps its descriptions and subtitles together and other
// software finds them (docs/architecture.md, 9.4):
//
//   Talk.webm              the file
//   Talk.arca.json         its manifest: hashes, type, title, tags, layers
//   Talk.en.srt            subtitles, `<name>.<language>.srt` as video
//                          players (mpv, VLC, Kodi, Jellyfin) expect
//
// The name is the file's name without its extension. When two files in a
// folder differ only by extension (Song.mp3, Song.flac) each keeps its full
// name instead (Song.mp3.arca.json, Song.mp3.en.srt).

import 'dart:convert';
import 'dart:io';

const manifestSuffix = '.arca.json';
const manifestFormat = 'arca-manifest/1';

/// A subtitle file found beside a file: its path and language code, if the
/// name carries one.
class SubtitleFile {
  const SubtitleFile(this.path, this.language);
  final String path;
  final String? language;

  String get name => path.split('/').last;
}

class Sidecars {
  /// Names in each folder, read once and kept for a while: the state sent
  /// to the UI asks for every file on every update. Writes here drop the
  /// folder at once; files others drop in show up within [maxAge].
  final _listing = <String, (DateTime, List<String>)>{};
  static const maxAge = Duration(seconds: 30);

  static String _dir(String path) => path.substring(0, path.lastIndexOf('/'));
  static String _name(String path) => path.substring(path.lastIndexOf('/') + 1);

  static String stemOf(String name) {
    final dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }

  /// File names in [dir], from the cache.
  List<String> namesIn(String dir) => _names(dir);

  List<String> _names(String dir) {
    final known = _listing[dir];
    final now = DateTime.now();
    if (known != null && now.difference(known.$1) < maxAge) return known.$2;
    List<String> names;
    try {
      names = [
        for (final e in Directory(dir).listSync(followLinks: false))
          if (e is File) _name(e.path),
      ];
    } on FileSystemException {
      names = const [];
    }
    _listing[dir] = (now, names);
    return names;
  }

  /// Forget what is known about [dir] after writing or deleting there.
  void changed(String path) => _listing.remove(FileSystemEntity.isDirectorySync(path) ? path : _dir(path));

  /// Whether [name] is a sidecar rather than a file of its own.
  static bool isSidecar(String name) => name.endsWith(manifestSuffix) || name.toLowerCase().endsWith('.srt');

  /// Whether the file at [path] is the sidecar of a file beside it: every
  /// manifest is, and a .srt whose name starts with a sibling's name
  /// (Talk.en.srt beside Talk.webm). A lone .srt is a file of its own.
  bool belongsToSibling(String path) {
    final name = _name(path);
    if (name.endsWith(manifestSuffix)) return true;
    if (!name.toLowerCase().endsWith('.srt')) return false;
    return _names(_dir(path)).any((n) => !isSidecar(n) && (name.startsWith('${stemOf(n)}.') || name.startsWith('$n.')));
  }

  /// The base every sidecar of [file] is named from.
  String baseOf(String file) {
    final name = _name(file), stem = stemOf(name);
    if (stem == name) return file;
    final clash = _names(_dir(file)).any((n) => n != name && !isSidecar(n) && stemOf(n) == stem);
    return '${_dir(file)}/${clash ? name : stem}';
  }

  String manifestOf(String file) => '${baseOf(file)}$manifestSuffix';

  String subtitlePath(String file, String? language) =>
      language == null || language.isEmpty ? '${baseOf(file)}.srt' : '${baseOf(file)}.$language.srt';

  /// `<base>.srt` and `<base>.<lang>.srt` beside [file].
  List<SubtitleFile> subtitlesOf(String file) {
    final base = _name(baseOf(file));
    final pattern = RegExp('^${RegExp.escape(base)}(?:\\.([A-Za-z]{2,3}(?:[-_][A-Za-z0-9]+)?))?\\.srt\$');
    return [
      for (final n in _names(_dir(file)))
        if (pattern.firstMatch(n) case final m?) SubtitleFile('${_dir(file)}/$n', m[1]),
    ]..sort((a, b) => a.name.compareTo(b.name));
  }

  /// Every sidecar of [file] that exists.
  List<String> allOf(String file) => [
    if (File(manifestOf(file)).existsSync()) manifestOf(file),
    for (final s in subtitlesOf(file)) s.path,
  ];

  /// Reads the manifest beside [file]; null when there is none or it does
  /// not describe these bytes.
  Map<String, Object?>? readManifest(String file, {String? sha256}) {
    final f = File(manifestOf(file));
    if (!f.existsSync()) return null;
    try {
      final m = (jsonDecode(f.readAsStringSync()) as Map).cast<String, Object?>();
      if (sha256 != null && m['sha256'] != sha256) return null;
      return m;
    } catch (_) {
      return null;
    }
  }

  /// Writes the manifest beside [file], through a temporary file so a copy
  /// never picks up half of one.
  Future<void> writeManifest(String file, Map<String, Object?> manifest) async {
    final path = manifestOf(file);
    final tmp = File('${_dir(path)}/.${_name(path)}.tmp');
    await tmp.writeAsString('${const JsonEncoder.withIndent('  ').convert(manifest)}\n', flush: true);
    await tmp.rename(path);
    changed(path);
  }
}
