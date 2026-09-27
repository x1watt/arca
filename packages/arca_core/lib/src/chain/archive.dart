// The headers of a node's chain, kept so newcomers can check it
// (chain/verify.dart). A node keeps no blocks older than its snapshot, but
// it keeps every header from where its own check started (its anchor):
// with the mining proof when it has it, as a summary otherwise. It serves
// summaries in pages and single headers with their proofs.
//
// Kept in memory and written as one file with the snapshot. At about
// 3 KB a header with its proof, that is fine for the test network; the
// main network (1440 blocks a day) would want the file indexed on disk
// and only recent proofs in memory.

import 'dart:convert';
import 'dart:io';

import 'fraud.dart';
import 'verify.dart';

class HeaderArchive {
  HeaderArchive(this.file, this.anchor);

  final File file;

  /// Where this archive starts: its first header follows it.
  Anchor anchor;
  final _headers = <Header>[];
  final _byHash = <String, int>{};

  int get height => anchor.height + _headers.length;
  Header? get tip => _headers.isEmpty ? null : _headers.last;
  String get tipHash => tip?.hash ?? anchor.hash;

  Header? at(int h) {
    final i = h - anchor.height - 1;
    return i >= 0 && i < _headers.length ? _headers[i] : null;
  }

  /// The header with [hash], with its proof when this archive has it.
  Header? byHash(String hash) {
    final i = _byHash[hash];
    return i == null ? null : _headers[i];
  }

  /// Takes [chain] (oldest first) as this node's chain from its first
  /// header on, replacing what followed. False when it does not connect.
  bool put(List<Header> chain) {
    if (chain.isEmpty) return true;
    final first = chain.first;
    if (first.height <= anchor.height || first.height > height + 1) return false;
    final parent = first.height == anchor.height + 1 ? anchor.hash : at(first.height - 1)!.hash;
    if (first.prev != parent) return false;
    final keep = first.height - anchor.height - 1;
    for (final h in _headers.skip(keep)) {
      _byHash.remove(h.hash);
    }
    _headers.removeRange(keep, _headers.length);
    for (final h in chain) {
      // A full header replaces the summary of the same block.
      _byHash[h.hash] = _headers.length;
      _headers.add(h);
    }
    return true;
  }

  /// Adds a proof to a header held as a summary.
  void fill(Header full) {
    final i = _byHash[full.hash];
    if (i != null && _headers[i].isSummary && !full.isSummary) _headers[i] = full;
  }

  /// Up to [n] summaries from height [from].
  List<Header> summaries(int from, int n) => [
    for (var h = from; h < from + n && h <= height; h++)
      if (at(h) case final x?) x.summary,
  ];

  Future<void> load() async {
    if (!await file.exists()) return;
    try {
      final j = jsonDecode(await file.readAsString()) as Map;
      anchor = Anchor.fromJson(j['anchor'] as Map);
      _headers.clear();
      _byHash.clear();
      put([for (final h in j['headers'] as List) Header.fromJson(h as Map)]);
    } on Object {
      // An archive this version cannot read: start it again.
    }
  }

  Future<void> save() async {
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(
      jsonEncode({
        'anchor': anchor.toJson(),
        'headers': [for (final h in _headers) h.toJson()],
      }),
    );
    await tmp.rename(file.path);
  }
}
