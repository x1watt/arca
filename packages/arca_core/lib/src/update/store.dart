// The device's updates folder (docs/architecture.md, 11): the newest
// release announcement it has checked, and the files of that release it
// holds, which it serves to others by SHA-256. Older files are deleted as
// soon as a newer release is adopted, so the folder holds one release at
// most.
//
// Two messages on the same link as Nostr and files ask for and announce a
// release; like the file messages they start with a byte that can never
// start a Nostr message:
//
//   QUERY   0xB1                         who has a release?
//   ANSWER  0xB2 json                    {"release": <event>, "have": [sha256...]}

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as c;

import '../library/library.dart' show hashFile;
import '../nostr/event.dart';
import 'release.dart';

const updateQueryTag = 0xB1, updateAnswerTag = 0xB2;

final updateQuery = Uint8List.fromList([updateQueryTag]);

/// The seeds of the updates meeting point: an I2P address made from the
/// release key, which every device holding files of the newest release
/// answers for, like a test network's meeting point.
(Uint8List, Uint8List) updateMeetingSeeds(String releaseKey) => (
  Uint8List.fromList(c.sha256.convert(utf8.encode('arca-updates-enc:$releaseKey')).bytes),
  Uint8List.fromList(c.sha256.convert(utf8.encode('arca-updates-sign:$releaseKey')).bytes),
);

Uint8List encodeUpdateAnswer(NostrEvent release, Iterable<String> have) {
  final json = utf8.encode(jsonEncode({'release': release.toJson(), 'have': have.toList()}));
  return Uint8List(json.length + 1)
    ..[0] = updateAnswerTag
    ..setRange(1, json.length + 1, json);
}

/// The event and the files an answer names, or null when it does not
/// parse. The event is not verified here.
(NostrEvent, Set<String>)? decodeUpdateAnswer(Uint8List bytes) {
  if (bytes.isEmpty || bytes[0] != updateAnswerTag) return null;
  try {
    final m = jsonDecode(utf8.decode(Uint8List.sublistView(bytes, 1)));
    if (m is! Map) return null;
    final e = NostrEvent.fromJson(m['release']);
    final have = {for (final h in m['have'] as List? ?? const []) '$h'};
    return (e, have);
  } on FormatException {
    return null;
  } on TypeError {
    return null;
  }
}

class UpdateStore {
  UpdateStore(this.dir, {this.key = trustedReleaseKey});

  final String dir;

  /// The release key this device trusts.
  final String key;

  Release? release;

  /// Files of [release] held here and checked, by SHA-256.
  final _held = <String, String>{};

  File get _eventFile => File('$dir/release.json');

  File fileOf(ReleaseAsset a) => File('$dir/${a.name}');

  /// Reads the release kept from the last run. A file is counted as held
  /// when its size is right: it only got its name after its hash was
  /// checked (a download is renamed into place when it matches).
  Future<void> load() async {
    await Directory(dir).create(recursive: true);
    if (!await _eventFile.exists()) return;
    try {
      release = Release.verify(NostrEvent.fromJson(jsonDecode(await _eventFile.readAsString())), key: key);
    } on Object {
      release = null;
      return;
    }
    for (final a in release!.assets) {
      final f = fileOf(a);
      if (await f.exists() && await f.length() == a.size) _held[a.sha256] = f.path;
    }
  }

  /// Takes [r] when it is newer than the release held: keeps its
  /// announcement and deletes the files of the older one. True when taken.
  Future<bool> adopt(Release r) async {
    if (!r.newerThan(release)) return false;
    // Taken before the first await, so two answers that arrive together
    // cannot both adopt.
    release = r;
    _held.clear();
    await Directory(dir).create(recursive: true);
    final tmp = File('${_eventFile.path}.tmp');
    await tmp.writeAsString(jsonEncode(r.event.toJson()), flush: true);
    await tmp.rename(_eventFile.path);
    // Every file of the old release goes, even one with the same name (its
    // bytes differ), and so do unfinished downloads.
    await for (final e in Directory(dir).list()) {
      final name = e.uri.pathSegments.lastWhere((s) => s.isNotEmpty);
      if (e is! File || name == 'release.json' || name.startsWith('arca-update.')) continue;
      await e.delete();
    }
    return true;
  }

  /// The path of a held file with [sha256], for serving; null otherwise.
  String? pathOf(String sha256) => _held[sha256];

  bool holds(String sha256) => _held.containsKey(sha256);

  Iterable<String> get held => _held.keys;

  /// Records that [a] arrived in its place, after the size check; the hash
  /// was checked by whoever wrote it there.
  Future<bool> markHeld(ReleaseAsset a) async {
    final f = fileOf(a);
    if (release?.assetBySha(a.sha256) == null || !await f.exists() || await f.length() != a.size) return false;
    _held[a.sha256] = f.path;
    return true;
  }

  /// Deletes the file of [a] (it no longer matched) so it is fetched again.
  Future<void> forget(ReleaseAsset a) async {
    _held.remove(a.sha256);
    final f = fileOf(a);
    if (await f.exists()) await f.delete();
  }

  /// Checks [a] against [file] (size and SHA-256, read again from disk).
  static Future<bool> matches(ReleaseAsset a, File file) async {
    if (!await file.exists() || await file.length() != a.size) return false;
    final (sha, _, _) = await hashFile(file);
    return sha == a.sha256;
  }

  /// Copies [source] in as [a] when it matches; false otherwise.
  Future<bool> importFile(ReleaseAsset a, File source) async {
    if (release?.assetBySha(a.sha256) == null || !await matches(a, source)) return false;
    final part = File('${fileOf(a).path}.part');
    await source.copy(part.path);
    if (!await matches(a, part)) {
      await part.delete();
      return false;
    }
    await part.rename(fileOf(a).path);
    _held[a.sha256] = fileOf(a).path;
    return true;
  }
}
