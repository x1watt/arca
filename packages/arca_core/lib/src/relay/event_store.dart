// Event storage for a profile's relay. Events are kept in memory and, for
// FileEventStore, appended to a JSON-lines log. SQLite replaces the log once
// stores grow (docs/architecture.md, 6); the interface stays the same.

import 'dart:convert';
import 'dart:io';

import '../nostr/event.dart';
import '../nostr/filter.dart';

enum AddResult { added, duplicate, replacedOlder, olderThanStored, deleted }

abstract class EventStore {
  /// Stores a verified event, applying NIP-01 replacement rules and NIP-09
  /// deletions by the same author.
  Future<AddResult> add(NostrEvent event);

  /// Events matching any filter, newest first, each filter's limit applied.
  Future<List<NostrEvent>> query(List<NostrFilter> filters);

  Future<NostrEvent?> byId(String id);

  Future<int> count();

  Future<void> close();
}

class MemoryEventStore implements EventStore {
  final _byId = <String, NostrEvent>{};

  /// For replaceable and addressable events: key to the current id.
  final _current = <String, String>{};

  /// Ids deleted by their authors, so late copies are refused.
  final _deleted = <String>{};

  String? _replaceKey(NostrEvent e) {
    if (e.isReplaceable) return '${e.kind}:${e.pubkey}';
    if (e.isAddressable) return '${e.kind}:${e.pubkey}:${e.dTag}';
    return null;
  }

  @override
  Future<AddResult> add(NostrEvent e) async => addSync(e);

  AddResult addSync(NostrEvent e) {
    if (e.isEphemeral) return AddResult.added;
    if (_byId.containsKey(e.id)) return AddResult.duplicate;
    if (_deleted.contains(e.id)) return AddResult.deleted;

    if (e.kind == Kind.deletion) {
      for (final id in e.tagValues('e')) {
        final target = _byId[id];
        if (target == null) {
          _deleted.add(id);
        } else if (target.pubkey == e.pubkey) {
          _remove(target);
          _deleted.add(id);
        }
      }
    }

    final key = _replaceKey(e);
    var result = AddResult.added;
    if (key != null) {
      final oldId = _current[key];
      final old = oldId == null ? null : _byId[oldId];
      if (old != null) {
        final newer = e.createdAt > old.createdAt ||
            (e.createdAt == old.createdAt && e.id.compareTo(old.id) < 0);
        if (!newer) return AddResult.olderThanStored;
        _byId.remove(old.id);
        result = AddResult.replacedOlder;
      }
      _current[key] = e.id;
    }
    _byId[e.id] = e;
    return result;
  }

  void _remove(NostrEvent e) {
    _byId.remove(e.id);
    final key = _replaceKey(e);
    if (key != null && _current[key] == e.id) _current.remove(key);
  }

  @override
  Future<List<NostrEvent>> query(List<NostrFilter> filters) async {
    final out = <String, NostrEvent>{};
    final sorted = _byId.values.toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    for (final f in filters) {
      var n = 0;
      for (final e in sorted) {
        if (f.limit != null && n >= f.limit!) break;
        if (f.matches(e)) {
          out[e.id] = e;
          n++;
        }
      }
    }
    return out.values.toList()..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  @override
  Future<NostrEvent?> byId(String id) async => _byId[id];

  @override
  Future<int> count() async => _byId.length;

  @override
  Future<void> close() async {}
}

/// A [MemoryEventStore] that survives restarts: every stored event is
/// appended to [file] and replayed on [open].
class FileEventStore extends MemoryEventStore {
  FileEventStore._(this.file, this._sink);

  final File file;
  final IOSink _sink;

  static Future<FileEventStore> open(File file) async {
    await file.parent.create(recursive: true);
    final store = FileEventStore._(file, file.openWrite(mode: FileMode.append));
    if (await file.exists()) {
      final lines = await file.openRead().transform(utf8.decoder).transform(const LineSplitter()).toList();
      for (final line in lines) {
        if (line.trim().isEmpty) continue;
        try {
          store.addSync(NostrEvent.fromJson(jsonDecode(line)));
        } on FormatException {
          // A torn last line after a crash; skip it.
        }
      }
    }
    return store;
  }

  @override
  Future<AddResult> add(NostrEvent e) async {
    final r = addSync(e);
    if ((r == AddResult.added || r == AddResult.replacedOlder) && !e.isEphemeral) {
      _sink.writeln(jsonEncode(e.toJson()));
    }
    return r;
  }

  @override
  Future<void> close() async {
    await _sink.flush();
    await _sink.close();
  }
}
