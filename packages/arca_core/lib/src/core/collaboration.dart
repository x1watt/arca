// Working on collections together (docs/architecture.md, 4.7): roles,
// changes signed by moderators and folded into the admin's collection,
// copies kept in sync, and deliveries that wait for someone to come online.

part of 'core_service.dart';

extension _Collaboration on CoreService {
  String _pubkeyOf(String profileId) => _store.profiles.firstWhere((p) => p.id == profileId).pubkey;

  Future<SyncStore> _syncStore(String profileId) =>
      _syncStores[profileId] ??= SyncStore.open(File('${_store.profileDir(profileId).path}/synced.json'));

  /// A path from someone else's index that stays inside the folder it is
  /// written to: relative, no `..`, no empty parts.
  static bool _safeRel(String path) {
    if (path.isEmpty || path.startsWith('/') || path.contains('\\') || path.contains('\x00')) return false;
    final parts = path.split('/');
    return parts.every((p) => p.isNotEmpty && p != '.' && p != '..');
  }

  static String _safeName(String name) =>
      name.replaceAll(RegExp(r'[/\\:*?"<>|\x00-\x1f]'), '_').replaceAll(RegExp(r'^[. ]+|[. ]+$'), '');

  // ---- Serving files ----

  /// The file this profile shares with [sha256]: from its collections or
  /// the copies it keeps.
  Future<String?> _resolveSha(String profileId, String sha256) async {
    var map = _shaPaths[profileId];
    if (map == null) {
      map = <String, String>{};
      for (final c in (await _library(profileId)).collections) {
        for (final f in c.files) {
          map[f.sha256] = '${c.folder}/${f.path}';
        }
      }
      for (final s in (await _syncStore(profileId)).items) {
        for (final e in s.files.entries) {
          map[e.value] = '${s.folder}/${e.key}';
        }
      }
      _shaPaths[profileId] = map;
    }
    final path = map[sha256];
    return path != null && await File(path).exists() ? path : null;
  }

  // ---- Who may change a collection ----

  /// Relay rule for this profile's collections: changes and decisions on
  /// suggestions only from the admin (this profile) and its moderators.
  Future<String?> _rolePolicy(String profileId, NostrEvent e) async {
    final guarded =
        e.kind == kindCollectionChange || (e.kind == Kind.reaction && e.tagValues('k').contains('$kindProposal'));
    if (!guarded) return null;
    final me = _pubkeyOf(profileId);
    for (final a in e.tagValues('a')) {
      final parts = a.split(':');
      if (parts.length != 3 || parts[1] != me) continue;
      final col = (await _library(profileId)).collections.where((c) => c.id == parts[2]).firstOrNull;
      if (col == null) return 'invalid: no such collection';
      return col.isModerator(e.pubkey) ? null : 'restricted: not a moderator of this collection';
    }
    return e.kind == kindCollectionChange ? 'invalid: not about a collection of this relay\'s owner' : null;
  }

  // ---- The admin folds moderators' changes into its collections ----

  Future<void> _foldIncoming(String profileId) async {
    if (!_folding.add(profileId)) {
      _foldAgain.add(profileId);
      return;
    }
    try {
      do {
        _foldAgain.remove(profileId);
        final me = _pubkeyOf(profileId);
        final lib = await _library(profileId);
        final changes = await (await _eventStore(profileId)).query([
          NostrFilter(
            kinds: const [kindCollectionChange],
            tags: {
              'p': [me],
            },
          ),
        ]);
        for (final col in lib.collections) {
          final address = '${Kind.arcaCollection}:$me:${col.id}';
          final todo =
              changes
                  .where(
                    (c) => c.tagValues('a').contains(address) && !col.hasApplied(c.id) && col.isModerator(c.pubkey),
                  )
                  .toList()
                ..sort(
                  (a, b) => a.createdAt != b.createdAt ? a.createdAt.compareTo(b.createdAt) : a.id.compareTo(b.id),
                );
          var changed = false;
          for (final c in todo) {
            // In order: a change waits while its file cannot be fetched yet.
            if (!await _applyToLibrary(profileId, lib, col, c)) break;
            await lib.markApplied(col.id, c.id, c.createdAt);
            changed = true;
          }
          if (changed) await _publishCollection(col, profileId);
        }
      } while (_foldAgain.contains(profileId));
    } finally {
      _folding.remove(profileId);
      _shaPaths.remove(profileId);
    }
    _push();
  }

  /// Applies one moderator's change to the admin's library. False when it
  /// has to wait (a new file that cannot be fetched yet).
  Future<bool> _applyToLibrary(String profileId, Library lib, Collection col, NostrEvent change) async {
    for (final op in CollectionIndex.operations(change)) {
      final path = op['path'] as String?, sha = op['sha256'] as String?;
      if (path == null || sha == null || !_safeRel(path)) continue;
      final current = col.files.where((f) => f.path == path).firstOrNull;
      switch (op['op']) {
        case 'edit':
          if (current == null || current.sha256 != sha) continue;
          await lib.updateFile(
            col.id,
            path,
            title: op['title'] as String?,
            description: op['description'] as String?,
            tags: (op['tags'] as List?)?.cast<String>(),
          );
        case 'remove':
          // Leaves the admin's own file on disk; it is only no longer listed.
          if (current == null || current.sha256 != sha) continue;
          await lib.removeFile(col.id, path);
        case 'add':
          if (current != null) continue;
          final blobs = net.blobsOf(profileId);
          if (blobs == null) return false;
          final target = '${col.folder}/$path';
          final author = col.moderators.where((m) => m['pubkey'] == change.pubkey).firstOrNull?['address'];
          final r = await blobs.fetch(
            sha,
            (op['size'] as num?)?.toInt() ?? 0,
            [...?(op['providers'] as List?)?.cast<String>(), ?author],
            target,
            reader: await _readerSession(profileId),
          );
          if (!r.ok) return false;
          await lib.adopt(
            col.id,
            target,
            title: op['title'] as String? ?? '',
            description: op['description'] as String? ?? '',
            tags: (op['tags'] as List?)?.cast<String>() ?? const [],
          );
      }
    }
    return true;
  }

  // ---- Delivering signed events that wait for their recipient ----

  /// Sends [e] to each of [to]; addresses that did not answer go to [f]'s
  /// outbox for the next refresh. Returns a refusal message, if any.
  Future<String?> _deliver(String profileId, Follow f, NostrEvent e, List<String> to) async {
    final node = net.nodeOf(profileId);
    final left = <String>[];
    String? refused;
    for (final a in to.toSet()) {
      if (node == null) {
        left.add(a);
        continue;
      }
      final r = await node.publish(a, e, attempts: 2, timeout: const Duration(seconds: 20));
      if (r.accepted) continue;
      if (r.timedOut) {
        left.add(a);
      } else {
        refused ??= r.message;
      }
    }
    if (left.isNotEmpty) f.outbox.add({'event': e.toJson(), 'to': left});
    return refused;
  }

  Future<void> _deliverOutbox(String profileId, Follow f) async {
    final node = net.nodeOf(profileId);
    if (node == null || f.outbox.isEmpty) return;
    final keep = <Map<String, Object?>>[];
    for (final item in f.outbox) {
      final e = NostrEvent.fromJson(item['event']);
      final left = <String>[];
      for (final a in (item['to'] as List).cast<String>()) {
        final r = await node.publish(a, e, attempts: 1, timeout: const Duration(seconds: 20));
        if (!r.accepted && r.timedOut) left.add(a);
      }
      if (left.isNotEmpty) keep.add({'event': item['event'], 'to': left});
    }
    f.outbox = keep;
  }

  // ---- Reading someone's collections: their head, plus moderators' changes ----

  Future<void> _refreshFollow(String profileId, Follow f) async {
    final node = net.nodeOf(profileId);
    if (node == null) {
      f.error = net.state == NetState.up ? 'Your profile is not online.' : 'Not connected to I2P yet.';
      _push();
      return;
    }
    f.refreshing = true;
    f.error = null;
    _push();
    try {
      await _deliverOutbox(profileId, f);
      final me = _pubkeyOf(profileId);
      final events = await node.query(f.address, [
        NostrFilter(authors: [f.pubkey], kinds: const [Kind.profile, Kind.arcaCollection, Kind.arcaCollectionPage]),
        NostrFilter(
          kinds: const [kindCollectionChange],
          tags: {
            'p': [f.pubkey],
          },
        ),
      ], timeout: const Duration(seconds: 60));
      if (events.isEmpty && f.fetchedAt == null) {
        f.error = 'No answer yet. Their device may be offline, or their address is still spreading on I2P.';
        return;
      }
      final indexes = <String, CollectionIndex>{};
      final changes = <String, NostrEvent>{};
      final pages = {
        for (final e in events)
          if (e.kind == Kind.arcaCollectionPage && e.pubkey == f.pubkey) e.id: e,
      };
      for (final e in events) {
        if (e.kind == Kind.profile && e.pubkey == f.pubkey) {
          try {
            f.name = (jsonDecode(e.content) as Map)['name'] as String? ?? f.name;
          } catch (_) {}
        } else if (e.kind == Kind.arcaCollection && e.pubkey == f.pubkey) {
          final i = CollectionIndex.fromHead(e, pages: pages);
          if (i != null) indexes[i.id] = i;
        } else if (e.kind == kindCollectionChange) {
          changes[e.id] = e;
        }
      }
      // Moderators keep their own changes too: seen even while the admin is
      // away, and before the admin has folded them in.
      final moderatorAddresses = {
        for (final i in indexes.values)
          for (final m in i.moderators)
            if (m.address.isNotEmpty && m.pubkey != me) m.address,
      };
      await Future.wait([
        for (final a in moderatorAddresses)
          node
              .query(
                a,
                [
                  NostrFilter(
                    kinds: const [kindCollectionChange],
                    tags: {
                      'p': [f.pubkey],
                    },
                  ),
                ],
                timeout: const Duration(seconds: 20),
                attempts: 1,
              )
              .then((list) {
                for (final e in list) {
                  changes[e.id] = e;
                }
              })
              .catchError((_) {}),
      ]);
      // My own changes as a moderator count at once, delivered or not.
      for (final e in await (await _eventStore(profileId)).query([
        NostrFilter(
          authors: [me],
          kinds: const [kindCollectionChange],
          tags: {
            'p': [f.pubkey],
          },
        ),
      ])) {
        changes[e.id] = e;
      }
      for (final i in indexes.values) {
        i.fold(changes.values);
      }
      f.collections = {for (final i in indexes.values) i.id: i.toJson()};

      // Decisions on suggestions: mine, and those sent to me as a moderator.
      final store = await _eventStore(profileId);
      final asked = [
        for (final e in await store.query([
          NostrFilter(authors: [me], kinds: const [kindProposal]),
        ]))
          e.id,
        for (final e in await store.query([
          NostrFilter(
            kinds: const [kindProposal],
            tags: {
              'p': [me],
            },
          ),
        ]))
          if (e.tagValues('p').contains(f.pubkey)) e.id,
      ];
      if (asked.isNotEmpty) {
        final reactions = await node.query(f.address, [
          NostrFilter(kinds: const [Kind.reaction], tags: {'e': asked}),
        ], timeout: const Duration(seconds: 60));
        for (final d in reactions) {
          final target = d.tagValues('e').firstOrNull;
          if (target == null) continue;
          final collection = d.tagValues('a').map((a) => a.split(':').last).firstOrNull;
          final index = collection == null ? null : indexes[collection];
          final authorized = d.pubkey == f.pubkey || (index?.mayChange(d.pubkey) ?? false);
          if (authorized) f.decisions[target] = d.content == '-' ? 'rejected' : 'accepted';
        }
      }
      f.fetchedAt = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    } catch (e) {
      f.error = '$e';
    } finally {
      f.refreshing = false;
      await (await _followStore(profileId)).save();
      _push();
    }
    _background(_syncFollowed(profileId, f));
  }

  // ---- Keeping a copy ----

  Future<void> _syncFollowed(String profileId, Follow f) async {
    final store = await _syncStore(profileId);
    for (final s in store.items.where((s) => s.owner == f.pubkey)) {
      _background(_syncOne(profileId, f, s));
    }
  }

  Future<SyncedCollection> _syncEntry(String profileId, Follow f, String collection) async {
    final store = await _syncStore(profileId);
    final known = store.find(f.pubkey, collection);
    if (known != null) return known;
    final name = (f.collections[collection]?['name'] as String?) ?? collection;
    final owner = f.name.isNotEmpty ? f.name : npubEncode(fromHex(f.pubkey)).substring(0, 12);
    var folder = '$_defaultFolder/${_safeName('$name ($owner)')}';
    for (var n = 2; await Directory(folder).exists() && store.items.every((s) => s.folder != folder); n++) {
      folder = '$_defaultFolder/${_safeName('$name ($owner) $n')}';
    }
    await Directory(folder).create(recursive: true);
    final s = SyncedCollection(owner: f.pubkey, collection: collection, folder: folder);
    store.items.add(s);
    await store.save();
    return s;
  }

  Future<void> _syncOne(String profileId, Follow f, SyncedCollection s) async {
    if (s.running) return;
    final m = f.collections[s.collection];
    if (m == null) {
      s.error = 'This collection is no longer shared.';
      _push();
      return;
    }
    if (m['complete'] == false) {
      s.error = 'This collection lists too many files for one event; copying it is not possible yet.';
      _push();
      return;
    }
    s
      ..running = true
      ..error = null;
    final files = [for (final x in m['files'] as List) IndexFile.fromJson(x as Map)];
    final providers = [
      f.address,
      for (final x in m['moderators'] as List? ?? const []) (x as Map)['address'] as String,
    ].where((a) => a.isNotEmpty).toList();
    s
      ..total = files.length
      ..done = 0
      ..totalBytes = files.fold(0, (n, x) => n + x.size)
      ..bytes = 0;
    _push();
    final store = await _syncStore(profileId);
    // Each push rebuilds the whole state for the UI, and each save rewrites
    // the whole record: both at most twice a second, not once per file.
    var lastReport = DateTime.now();
    Future<void> report() async {
      if (DateTime.now().difference(lastReport) < const Duration(milliseconds: 500)) return;
      lastReport = DateTime.now();
      await store.save();
      _push();
    }

    try {
      for (final file in files) {
        if (_closing) break;
        if (!_safeRel(file.path)) continue;
        final target = '${s.folder}/${file.path}';
        final base = s.bytes;
        if (s.files[file.path] != file.sha256 || !await File(target).exists()) {
          final blobs = net.blobsOf(profileId);
          if (blobs == null) {
            s.error = 'Not connected, so the copy is not complete.';
            break;
          }
          var lastPush = DateTime.now();
          final r = await blobs.fetch(
            file.sha256,
            file.size,
            [...file.providers, ...providers],
            target,
            reader: await _readerSession(profileId),
            onProgress: (n) {
              s.bytes = base + n;
              if (DateTime.now().difference(lastPush) > const Duration(milliseconds: 500)) {
                lastPush = DateTime.now();
                _push();
              }
            },
          );
          if (!r.ok) {
            s.error = r.error ?? 'Stopped.';
            s.bytes = base;
            continue;
          }
          s.files[file.path] = file.sha256;
          _shaPaths.remove(profileId);
        }
        await _sidecars.writeManifest(target, {
          'format': manifestFormat,
          'file': file.path.split('/').last,
          'size': file.size,
          'sha256': file.sha256,
          'mime': file.mime,
          'title': file.title,
          'description': file.description,
          'tags': file.tags,
          'collection': {'admin': f.pubkey, 'id': s.collection, 'name': m['name']},
          'layers': const [],
        });
        s.done++;
        s.bytes = base + file.size;
        await report();
      }
      // Files the collection listed before and no longer does leave the
      // copy; the folder's other files are left alone.
      final listed = {for (final x in files) x.path};
      for (final path in s.files.keys.toList()) {
        if (listed.contains(path) || !s.listed.contains(path)) continue;
        final target = '${s.folder}/$path';
        for (final p in [..._sidecars.allOf(target), target]) {
          final file = File(p);
          if (await file.exists()) await file.delete();
        }
        _sidecars.changed(target);
        s.files.remove(path);
      }
      s.listed = listed;
      s.heldBytes = files.where((x) => s.files[x.path] == x.sha256).fold(0, (n, x) => n + x.size);
      s.syncedAt = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    } finally {
      s.running = false;
      _shaPaths.remove(profileId);
      await store.save();
      _push();
    }
  }

  // ---- A moderator changes someone else's collection ----

  /// Signs [ops] (plus files added from [addPaths]) as a change to [f]'s
  /// collection [collection], keeps it and delivers it to the admin.
  Future<String?> _moderate(
    String profileId,
    Follow f,
    String collection,
    List<Map<String, Object?>> ops,
    List<String> addPaths, {
    String? acceptsProposal,
  }) async {
    final me = _pubkeyOf(profileId);
    final m = f.collections[collection];
    if (m == null) return 'That collection is not shared anymore.';
    final index = CollectionIndex(
      admin: f.pubkey,
      id: collection,
      name: '',
      moderators: [
        for (final x in m['moderators'] as List? ?? const [])
          Moderator((x as Map)['pubkey'] as String, x['address'] as String? ?? ''),
      ],
    );
    if (!index.mayChange(me)) return 'Only the admin and moderators can change this collection.';
    final all = [...ops];
    if (addPaths.isNotEmpty) {
      // New files go into this profile's copy of the collection, which is
      // what it serves them from.
      final s = await _syncEntry(profileId, f, collection);
      final taken = {for (final x in m['files'] as List) (x as Map)['path'] as String, ...s.files.keys};
      for (final src in addPaths) {
        final name = src.split(Platform.pathSeparator).last;
        var path = name;
        for (var n = 2; taken.contains(path); n++) {
          final dot = name.lastIndexOf('.');
          path = dot > 0 ? '${name.substring(0, dot)} ($n)${name.substring(dot)}' : '$name ($n)';
        }
        taken.add(path);
        final target = File('${s.folder}/$path');
        await target.parent.create(recursive: true);
        await File(src).copy(target.path);
        final (sha, _, size) = await hashFile(target);
        s.files[path] = sha;
        all.add({
          'op': 'add',
          'path': path,
          'sha256': sha,
          'size': size,
          'mime': await detectMime(target),
          'title': name.contains('.') ? name.substring(0, name.lastIndexOf('.')) : name,
          'providers': [await _address(profileId)],
        });
      }
      await (await _syncStore(profileId)).save();
      _shaPaths.remove(profileId);
    }
    if (all.isEmpty) return null;
    final e = await _publishLocal(profileId, kindCollectionChange, jsonEncode({'ops': all}), [
      ['a', '${Kind.arcaCollection}:${f.pubkey}:$collection'],
      ['p', f.pubkey],
      if (acceptsProposal != null) ['e', acceptsProposal],
    ]);
    final refused = await _deliver(profileId, f, e, [f.address]);
    await (await _followStore(profileId)).save();
    if (refused != null) return 'The admin refused the change: $refused';
    _background(_refreshFollow(profileId, f));
    return null;
  }
}
