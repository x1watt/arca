part of 'core_service.dart';

// What a profile keeps for itself (docs/architecture.md, 3.6): its search
// history, the files it opened, and the files it liked. Likes are public
// (NIP-25 kind 17 on the file's `arca:sha256:` identifier, which in Arca
// also means "I share it"); the two histories never leave the device.
// Each list is loaded once and kept in memory, so building the state reads
// no disk (docs/performance.md, 3.6).

extension _Personal on CoreService {
  File _personalFile(String id, String name) => File('${_store.profileDir(id).path}/$name.json');

  Future<List<Map<String, Object?>>> _personalList(String id, String name) {
    return _personal.putIfAbsent('$id/$name', () async {
      final f = _personalFile(id, name);
      if (!await f.exists()) return <Map<String, Object?>>[];
      try {
        return [for (final e in jsonDecode(await f.readAsString()) as List) (e as Map).cast<String, Object?>()];
      } on FormatException {
        return <Map<String, Object?>>[];
      }
    });
  }

  /// The list as last loaded, for the state (never reads the disk).
  List<Map<String, Object?>> _personalNow(String id, String name) => _personalLoaded['$id/$name'] ?? const [];

  Future<void> _savePersonal(String id, String name, List<Map<String, Object?>> list) async {
    _personalLoaded['$id/$name'] = list;
    final f = _personalFile(id, name);
    await f.parent.create(recursive: true);
    await File('${f.path}.tmp').writeAsString(jsonEncode(list));
    await File('${f.path}.tmp').rename(f.path);
  }

  /// Loads the lists of [id] into memory (called when it becomes active).
  Future<void> _loadPersonal(String id) async {
    for (final name in ['searches', 'opened']) {
      _personalLoaded['$id/$name'] = await _personalList(id, name);
    }
    await _loadLikes(id);
  }

  /// Adds [entry] at the top of a list, without duplicates by [key], keeping
  /// at most [max].
  Future<void> _remember(String id, String name, Map<String, Object?> entry, String key, int max) async {
    final list = [...await _personalList(id, name)]..removeWhere((e) => e[key] == entry[key]);
    list.insert(0, entry);
    if (list.length > max) list.removeRange(max, list.length);
    _personal['$id/$name'] = Future.value(list);
    await _savePersonal(id, name, list);
  }

  Future<void> _forget(String id, String name) async {
    _personal['$id/$name'] = Future.value(<Map<String, Object?>>[]);
    await _savePersonal(id, name, []);
  }

  // ---- Likes ----

  static String _fileTarget(String sha256) => 'arca:sha256:$sha256';

  /// The files [id] likes, from its own relay: kind 17 events it signed.
  Future<void> _loadLikes(String id) async {
    final store = await _eventStore(id);
    final events = await store.query([
      NostrFilter(kinds: const [Kind.externalReaction], authors: [_pubkeyOf(id)]),
    ]);
    _likes[id] = {
      for (final e in events)
        for (final t in e.tagValues('i'))
          if (t.startsWith('arca:sha256:')) t.substring('arca:sha256:'.length): e.id,
    };
  }

  Future<void> _like(String id, String sha256, bool on) async {
    final likes = _likes[id] ??= {};
    if (on == likes.containsKey(sha256)) return;
    if (on) {
      final e = await _publishLocal(id, Kind.externalReaction, '+', [
        ['i', _fileTarget(sha256)],
        ['k', 'arca'],
      ]);
      likes[sha256] = e.id;
    } else {
      // NIP-09: withdraw the like.
      await _publishLocal(id, Kind.deletion, '', [
        ['e', likes[sha256]!],
        ['k', '${Kind.externalReaction}'],
      ]);
      likes.remove(sha256);
    }
  }

  // ---- Space for other people's notes ----

  /// Keeps what each profile's relay stores for others within the limit in
  /// Settings, dropping the oldest first. The profile's own events always
  /// stay.
  Future<void> _pruneNotes() async {
    final limit = _noteSpace;
    for (final p in _store.profiles) {
      final store = await _eventStore(p.id);
      final dropped = await store.prune(limit, (e) => e.pubkey != p.pubkey);
      if (dropped > 0) stderr.writeln('notes: dropped $dropped old events of others for ${p.id}');
    }
  }

  Future<Map<String, Object?>?> _personalCommand(String command, Map<String, Object?> args) async {
    final id = _activeId;
    switch (command) {
      case 'rememberSearch':
        final q = (args['query'] as String? ?? '').trim();
        if (q.isNotEmpty) await _remember(id, 'searches', {'query': q, 'at': _now()}, 'query', 50);
      case 'clearSearches':
        await _forget(id, 'searches');
      case 'forgetSearch':
        final list = [...await _personalList(id, 'searches')]..removeWhere((e) => e['query'] == args['query']);
        _personal['$id/searches'] = Future.value(list);
        await _savePersonal(id, 'searches', list);
      case 'opened':
        await _remember(
          id,
          'opened',
          {
            'sha256': args['sha256'],
            'name': args['name'],
            'mime': args['mime'],
            'collection': args['collection'],
            'owner': args['owner'],
            'at': _now(),
          },
          'sha256',
          200,
        );
      case 'clearOpened':
        await _forget(id, 'opened');
      case 'like':
        await _like(id, args['sha256'] as String, args['on'] as bool? ?? true);
      default:
        return {'error': 'unknown command $command'};
    }
    return null;
  }

  static int _now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;
}
