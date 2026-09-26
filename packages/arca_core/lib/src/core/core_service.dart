// The core isolate (docs/architecture.md, 7): owns the profile store, keys,
// event stores and the network, and answers the UI with plain maps. The UI
// never sees a secret except when the user explicitly exports one.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:i2p/i2p.dart' show sharedDestinationAddress;

import '../crypto/hex.dart';
import '../library/collection_index.dart';
import '../library/library.dart';
import '../library/previews.dart';
import '../library/sidecars.dart';
import '../library/subtitles.dart';
import '../library/sync.dart';
import '../nostr/event.dart';
import '../nostr/filter.dart';
import '../nostr/nip19.dart';
import '../profiles/profile_store.dart';
import '../profiles/vault.dart';
import '../relay/event_store.dart';
import 'network.dart';
import 'social.dart';

part 'collaboration.dart';

class CoreService {
  CoreService._(this._store, this.net, this._dataDir, this._defaultBase);

  final ProfileStore _store;
  final NetworkManager net;
  final String _dataDir;
  final String _defaultBase;

  /// Device settings: storage folders shared by all profiles.
  List<String> _baseFolders = [];
  String _defaultFolder = '';
  // Futures, not values: `map[id] ??= await open()` lets two callers that
  // arrive together each open their own copy, and the last one assigned
  // silently drops what was written to the other (docs/performance.md, 3.1).
  final _libraries = <String, Future<Library>>{};
  final _follows = <String, Future<FollowStore>>{};
  late final VideoPreviews _previews = VideoPreviews('$_dataDir/previews');

  // Subtitles (docs/architecture.md, 9.3): the chosen speech model, whether
  // new videos and audio are done automatically, downloads in progress and
  // the queue of files waiting, done one at a time.
  late final ModelStore _models = ModelStore('$_dataDir/models');
  late final SubtitleStore _subtitles = SubtitleStore('$_dataDir/subtitles');
  late final Transcriber _transcriber = Transcriber(_subtitles);
  String? _whisperModel;
  bool _autoSubtitles = true;
  final _downloads = <String, int>{};
  final _downloadErrors = <String, String>{};
  final _stopDownloads = <String>{};
  final _subtitleQueue = <String, (String, String)>{};

  /// Files asked for by hand, done even when they already have subtitles.
  final _redo = <String>{};

  /// Manifests and subtitles beside the files, one cache for all profiles.
  final _sidecars = Sidecars();

  // Working together on collections (collaboration.dart).
  final _syncStores = <String, Future<SyncStore>>{};
  final _shaPaths = <String, Map<String, String>>{};
  final _folding = <String>{};
  final _tasks = <Future<void>>{};
  bool _closing = false;

  /// Runs [work] in the background, tracked so [close] can wait for it.
  void _background(Future<void> work) {
    if (_closing) return;
    final f = work.catchError((Object _) {});
    _tasks.add(f);
    f.whenComplete(() {
      _tasks.remove(f);
    });
  }

  final _foldAgain = <String>{};
  String? _subtitleSha;
  String _subtitleName = '';
  bool _subtitlesRunning = false;

  Future<FollowStore> _followStore(String profileId) =>
      _follows[profileId] ??= FollowStore.open(File('${_store.profileDir(profileId).path}/follows.json'));

  void _push() => unawaited(_state().then((s) => onPush?.call(s)));

  /// Decrypted secret keys of profiles in use, kept only in this isolate's
  /// memory (docs/architecture.md, 3.5) so signing does not rerun Argon2.
  final _keys = <String, Uint8List>{};

  Future<Uint8List> _secretKey(String id) async {
    final known = _keys[id];
    if (known != null) return known;
    final secrets = await _store.unlock(id);
    final key = Uint8List.fromList(secrets.secretKey);
    secrets.wipe();
    return _keys[id] = key;
  }

  void _forgetKey(String id) {
    final k = _keys.remove(id);
    k?.fillRange(0, k.length, 0);
  }

  /// Pushes unsolicited updates (network state) to the UI.
  void Function(Map<String, Object?> state)? onPush;

  /// I2P address per profile id, computed from the vault's seeds once.
  final _addresses = <String, String>{};
  final _stores = <String, Future<FileEventStore>>{};

  /// Opens the store and, unless [startNetwork] is false, starts the network
  /// in the background. [backend] defaults to I2P under the data folder.
  static Future<CoreService> open(
    String dataDir, {
    VaultCost cost = const VaultCost(),
    NetworkBackend? backend,
    bool startNetwork = true,
    String? defaultBaseFolder,
  }) async {
    final store = await ProfileStore.open(Directory(dataDir), cost: cost);
    await store.ensureProfile();
    late final CoreService s;
    final manager = NetworkManager(
      backend ?? I2pBackend('$dataDir/i2p'),
      onChange: () async => s.onPush?.call(await s._state()),
      onEvent: (profileId, e) {
        // A moderator's change reached this admin's relay.
        if (e.kind == kindCollectionChange) s._background(s._foldIncoming(profileId));
      },
    );
    s = CoreService._(store, manager, dataDir, defaultBaseFolder ?? '${Platform.environment['HOME'] ?? dataDir}/Arca');
    await s._loadSettings();
    for (final p in store.profiles) {
      await s._address(p.id);
      if (s._shouldBeOnline(p)) await s._goOnline(p);
    }
    if (startNetwork) manager.start();
    unawaited(s._makePreviews());
    unawaited(s._writeMissingManifests().then((_) => s._migrateSubtitles()).then((_) => s._queueSubtitles()));
    return s;
  }

  File get _settingsFile => File('$_dataDir/settings.json');

  Future<void> _loadSettings() async {
    if (await _settingsFile.exists()) {
      final m = jsonDecode(await _settingsFile.readAsString()) as Map<String, dynamic>;
      _baseFolders = (m['baseFolders'] as List).cast<String>().toList();
      _defaultFolder = m['defaultFolder'] as String;
      _whisperModel = m['whisperModel'] as String?;
      _autoSubtitles = m['autoSubtitles'] as bool? ?? true;
    }
    if (_baseFolders.isEmpty) {
      _baseFolders = [_defaultBase];
      _defaultFolder = _defaultBase;
      await _saveSettings();
    }
  }

  Future<void> _saveSettings() => _settingsFile.writeAsString(
    jsonEncode({
      'baseFolders': _baseFolders,
      'defaultFolder': _defaultFolder,
      'whisperModel': _whisperModel,
      'autoSubtitles': _autoSubtitles,
    }),
  );

  Future<Library> _library(String profileId) => _libraries[profileId] ??= Library.open(
    File('${_store.profileDir(profileId).path}/collections.json'),
    sidecars: _sidecars,
  );

  String get _activeId => _store.active!.id;

  /// Publishes the collection's head as an addressable event in the owner's
  /// relay: its files with their descriptions, its moderators, and the
  /// moderators' changes already folded in (docs/architecture.md, 4.7).
  Future<void> _publishCollection(Collection col, [String? profileId]) async {
    final files = [
      for (final f in col.files)
        {
          'path': f.path,
          'size': f.size,
          'sha256': f.sha256,
          'mime': f.mime,
          'title': f.title,
          if (f.description.isNotEmpty) 'description': f.description,
          if (f.tags.isNotEmpty) 'tags': f.tags,
        },
    ];
    final id = profileId ?? _activeId;
    var content = jsonEncode({'name': col.name, 'description': col.description, 'files': files});
    final pageTags = <List<String>>[];
    if (utf8.encode(content).length > maxHeadListBytes) {
      // Too big for one message: the list goes into page events, published
      // first, and the head names each page by event id, so a reader
      // always gets one consistent version.
      final pages = CollectionIndex.paginate(files);
      for (var n = 0; n < pages.length; n++) {
        final d = '${col.id}/$n';
        final page = await _publishLocal(id, Kind.arcaCollectionPage, pages[n], [
          ['d', d],
        ]);
        pageTags.add(['page', d, page.id]);
      }
      content = jsonEncode({'name': col.name, 'description': col.description, 'fileCount': files.length});
    }
    // The newest applied changes by name; older ones are covered by the
    // watermark, so the head stays one message however long its history.
    final applied = [
      for (final e in col.applied) (e.split('@').first, int.tryParse(e.contains('@') ? e.split('@').last : '') ?? 0),
    ]..sort((a, b) => b.$2.compareTo(a.$2));
    final named = applied.take(maxAppliedIds).toList();
    await _publishLocal(id, Kind.arcaCollection, content, [
      ['d', col.id],
      ['title', col.name],
      ['circle', 'arca:circle:${col.circle}'],
      for (final m in col.moderators) ['role', m['pubkey']!, 'moderator', m['address'] ?? ''],
      for (final (changeId, _) in named) ['applied', changeId],
      if (applied.length > named.length) ['folded', '${named.last.$2}'],
      ...pageTags,
    ]);
  }

  Future<int?> _freeBytes(String path) async {
    if (!Platform.isLinux && !Platform.isMacOS) return null;
    var dir = Directory(path);
    while (!await dir.exists() && dir.parent.path != dir.path) {
      dir = dir.parent;
    }
    final r = await Process.run('df', ['-Pk', dir.path]);
    final lines = (r.stdout as String).trim().split('\n');
    if (r.exitCode != 0 || lines.length < 2) return null;
    final cols = lines.last.split(RegExp(r'\s+'));
    return cols.length > 3 ? int.tryParse(cols[3])! * 1024 : null;
  }

  Future<Map<String, Object?>> _comments(String target) async {
    final store = await _eventStore(_activeId);
    final events = await store.query([
      NostrFilter(
        kinds: const [Kind.comment],
        tags: {
          'I': [target],
        },
      ),
    ]);
    final names = <String, String>{};
    for (final e in await store.query([
      NostrFilter(kinds: const [Kind.profile], authors: {for (final e in events) e.pubkey}.toList()),
    ])) {
      try {
        names[e.pubkey] = (jsonDecode(e.content) as Map)['name'] as String;
      } catch (_) {}
    }
    final me = _store.active!.pubkey;
    return {
      'comments': [
        for (final e in events.reversed)
          {
            'id': e.id,
            'pubkey': e.pubkey,
            'npub': npubEncode(fromHex(e.pubkey)),
            'name': names[e.pubkey] ?? (e.pubkey == me ? _store.active!.name : ''),
            'content': e.content,
            'createdAt': e.createdAt,
            'mine': e.pubkey == me,
          },
      ],
    };
  }

  /// Makes missing video previews for the active profile's library in the
  /// background, pushing the state after each one.
  Future<void> _makePreviews() async {
    if (_store.active == null || !await _previews.available()) return;
    final lib = await _library(_activeId);
    for (final c in lib.collections) {
      for (final f in c.files.where((f) => f.mime.startsWith('video/'))) {
        if (_previews.hasStill(f.sha256) && _previews.hasAnimated(f.sha256)) continue;
        if (await _previews.ensure('${c.folder}/${f.path}', f.sha256)) _push();
      }
    }
  }

  Map<String, Object?> _fileState(Collection c, LibraryFile f) {
    final subtitles = _sidecars.subtitlesOf('${c.folder}/${f.path}');
    final first = subtitles.firstOrNull;
    return {
      ...f.toJson(),
      if (_previews.hasStill(f.sha256)) 'still': _previews.still(f.sha256).path,
      if (_previews.hasAnimated(f.sha256)) 'animated': _previews.animated(f.sha256).path,
      if (first != null) ...{
        'subtitles': first.path,
        'subtitleLanguage': first.language,
        'subtitleMachine': f.layers.any((l) => l['file'] == first.name && l['origin'] == 'machine'),
      },
      if (_subtitles.failure(f.sha256) case final why?) 'subtitleError': why,
    };
  }

  bool _hasSubtitles(Collection c, LibraryFile f) => _sidecars.subtitlesOf('${c.folder}/${f.path}').isNotEmpty;

  /// Puts the subtitles made for [sha] beside every copy of that file in the
  /// active profile's collections, named `<file>.<language>.srt`, records
  /// them in each manifest, and replaces subtitles made earlier by a model.
  Future<void> _placeSubtitles(String sha, File made, WhisperModel model, String? language) async {
    final lib = await _library(_activeId);
    final layer = {
      'language': language,
      'origin': 'machine',
      'tool': 'whisper.cpp $whisperVersion',
      'model': model.file,
      'created': DateTime.now().toUtc().toIso8601String(),
    };
    for (final c in lib.collections) {
      for (final f in c.files.where((f) => f.sha256 == sha)) {
        final abs = '${c.folder}/${f.path}';
        final target = _sidecars.subtitlePath(abs, language);
        final targetName = target.split('/').last;
        // Written by a person or another tool: leave it and keep ours out.
        final foreign =
            File(target).existsSync() && !f.layers.any((l) => l['file'] == targetName && l['origin'] == 'machine');
        if (foreign) continue;
        for (final old in f.layers.where((l) => l['type'] == 'subtitles' && l['origin'] == 'machine').toList()) {
          final oldFile = File('${abs.substring(0, abs.lastIndexOf('/'))}/${old['file']}');
          if (old['file'] != targetName && await oldFile.exists()) await oldFile.delete();
          f.layers.remove(old);
        }
        await made.copy(target);
        _sidecars.changed(target);
        f.layers.add({'type': 'subtitles', 'file': targetName, ...layer});
        await lib.saveFile(c, f);
      }
    }
  }

  /// Files added before manifests existed get one beside them.
  Future<void> _writeMissingManifests() async {
    for (final p in _store.profiles) {
      final lib = await _library(p.id);
      for (final c in lib.collections) {
        for (final f in c.files) {
          final abs = '${c.folder}/${f.path}';
          if (!await File(abs).exists() || await File(_sidecars.manifestOf(abs)).exists()) continue;
          try {
            await lib.writeManifest(c, f);
          } on FileSystemException {
            // A read-only folder keeps working without manifests.
          }
        }
      }
    }
  }

  /// Subtitles made before they were kept beside the files
  /// (`subtitles/<sha256>.srt` in the data folder) move beside them.
  Future<void> _migrateSubtitles() async {
    final old = Directory('$_dataDir/subtitles');
    if (_store.active == null || !await old.exists()) return;
    final lib = await _library(_activeId);
    var moved = false;
    for (final c in lib.collections) {
      for (final f in c.files) {
        final srt = File('${old.path}/${f.sha256}.srt');
        if (!await srt.exists() || _hasSubtitles(c, f)) continue;
        final meta = File('${old.path}/${f.sha256}.json');
        final m = await meta.exists() ? jsonDecode(await meta.readAsString()) as Map : const {};
        final model = modelById(m['model'] as String?) ?? whisperModels.first;
        await _placeSubtitles(f.sha256, srt, model, m['language'] as String?);
        moved = true;
      }
    }
    if (moved) _push();
    await for (final e in old.list()) {
      if (e is File && (e.path.endsWith('.srt') || e.path.endsWith('.json'))) await e.delete();
    }
  }

  bool _hasSpeech(LibraryFile f) => f.mime.startsWith('video/') || f.mime.startsWith('audio/');

  WhisperModel? get _readyModel {
    final m = modelById(_whisperModel);
    return m != null && _models.installed(m) ? m : null;
  }

  /// Queues every video and audio file of the active profile that has no
  /// subtitles yet, when automatic subtitles are on and a model is ready.
  Future<void> _queueSubtitles() async {
    if (!_autoSubtitles || _store.active == null || _readyModel == null) return;
    if (!_transcriber.available()) return;
    final lib = await _library(_activeId);
    for (final c in lib.collections) {
      for (final f in c.files.where(_hasSpeech)) {
        if (_hasSubtitles(c, f) || _subtitles.failed(f.sha256)) continue;
        _subtitleQueue.putIfAbsent(f.sha256, () => ('${c.folder}/${f.path}', f.name));
      }
    }
    unawaited(_runSubtitles());
  }

  Future<void> _runSubtitles() async {
    if (_subtitlesRunning) return;
    _subtitlesRunning = true;
    try {
      while (_subtitleQueue.isNotEmpty) {
        final model = _readyModel;
        if (model == null) break;
        final sha = _subtitleQueue.keys.first;
        final (path, name) = _subtitleQueue.remove(sha)!;
        final redo = _redo.remove(sha);
        if (!redo && _sidecars.subtitlesOf(path).isNotEmpty) continue;
        _subtitleSha = sha;
        _subtitleName = name;
        _push();
        // Progress lives in native memory the worker writes; report it.
        var last = -2;
        final ticker = Timer.periodic(const Duration(seconds: 1), (_) {
          if (_transcriber.progress != last) {
            last = _transcriber.progress;
            _push();
          }
        });
        final r = await _transcriber.run(path, sha, _models.file(model).path);
        ticker.cancel();
        if (r.error != null) {
          await _subtitles.markFailed(sha, r.error!);
        } else if (r.cancelled) {
          await _subtitles.markFailed(sha, 'Stopped.');
        } else {
          final made = _subtitles.srt(sha);
          await _placeSubtitles(sha, made, model, r.language);
          await made.delete();
        }
        _subtitleSha = null;
        _push();
      }
    } finally {
      _subtitlesRunning = false;
      _subtitleSha = null;
    }
  }

  Future<void> _downloadModel(WhisperModel m) async {
    if (_downloads.containsKey(m.id) || _models.installed(m)) return;
    _downloads[m.id] = _models.partial(m);
    _downloadErrors.remove(m.id);
    _stopDownloads.remove(m.id);
    _push();
    var lastPush = DateTime.now();
    final error = await _models.download(
      m,
      onProgress: (n) {
        _downloads[m.id] = n;
        if (DateTime.now().difference(lastPush) > const Duration(milliseconds: 500)) {
          lastPush = DateTime.now();
          _push();
        }
      },
      cancelled: () => _stopDownloads.contains(m.id),
    );
    _downloads.remove(m.id);
    if (error != null) {
      if (!_stopDownloads.contains(m.id)) _downloadErrors[m.id] = error;
    } else {
      if (_readyModel == null) {
        _whisperModel = m.id;
        await _saveSettings();
      }
      await _queueSubtitles();
      unawaited(_runSubtitles());
    }
    _push();
  }

  Map<String, Object?> _subtitleState() => {
    'available': _transcriber.available(),
    'recommended': recommendedModel(),
    'selected': _whisperModel,
    'auto': _autoSubtitles,
    'models': [
      for (final m in whisperModels)
        {
          'id': m.id,
          'label': m.label,
          'detail': m.detail,
          'bytes': m.bytes,
          'installed': _models.installed(m),
          'downloading': _downloads.containsKey(m.id),
          'received': _downloads[m.id] ?? _models.partial(m),
          'error': _downloadErrors[m.id],
        },
    ],
    'queued': _subtitleQueue.length,
    'waiting': _subtitleQueue.keys.toList(),
    if (_subtitleSha != null)
      'current': {'sha256': _subtitleSha, 'name': _subtitleName, 'progress': _transcriber.progress},
  };

  /// Fetches what a followed profile publishes: its name, its collections,
  /// and the decisions on suggestions we sent it. Runs in the background.
  /// Suggestions sent to this profile, as admin or moderator of the
  /// collection, that nobody with the right to decide has decided yet.
  Future<List<Map<String, Object?>>> _proposals(String profileId) async {
    final me = _pubkeyOf(profileId);
    final store = await _eventStore(profileId);
    final incoming = [
      for (final e in await store.query([
        NostrFilter(
          kinds: const [kindProposal],
          tags: {
            'p': [me],
          },
        ),
      ]))
        if (e.pubkey != me) e,
    ];
    if (incoming.isEmpty) return const [];
    final lib = await _library(profileId);
    final follows = (await _followStore(profileId)).follows;
    final byId = {for (final e in incoming) e.id: e};
    final decided = <String>{for (final f in follows) ...f.decisions.keys.where(byId.containsKey)};
    for (final r in await store.query([
      NostrFilter(kinds: const [Kind.reaction], tags: {'e': byId.keys.toList()}),
    ])) {
      final target = r.tagValues('e').firstWhere(byId.containsKey, orElse: () => '');
      if (target.isEmpty) continue;
      final parts = (byId[target]!.tagValues('a').firstOrNull ?? '').split(':');
      final col = parts.length == 3 && parts[1] == me
          ? lib.collections.where((c) => c.id == parts[2]).firstOrNull
          : null;
      if (r.pubkey == me || (col?.isModerator(r.pubkey) ?? false)) decided.add(target);
    }
    final names = <String, String>{};
    for (final e in await store.query([
      NostrFilter(kinds: const [Kind.profile], authors: {for (final e in incoming) e.pubkey}.toList()),
    ])) {
      try {
        names[e.pubkey] = (jsonDecode(e.content) as Map)['name'] as String;
      } catch (_) {}
    }
    return [
      for (final e in incoming.where((e) => !decided.contains(e.id)))
        {
          'id': e.id,
          'from': e.pubkey,
          'fromName': names[e.pubkey] ?? ((jsonDecode(e.content) as Map)['fromName'] as String? ?? ''),
          'fromNpub': npubEncode(fromHex(e.pubkey)),
          'createdAt': e.createdAt,
          'owner': (e.tagValues('a').firstOrNull ?? '').split(':').elementAtOrNull(1) ?? me,
          ...(jsonDecode(e.content) as Map).cast<String, Object?>(),
        },
    ];
  }

  /// Suggestions this profile sent, with the owner's decision when known.
  Future<List<Map<String, Object?>>> _mySuggestions(String profileId) async {
    final me = _store.profiles.firstWhere((p) => p.id == profileId).pubkey;
    final sent = await (await _eventStore(profileId)).query([
      NostrFilter(authors: [me], kinds: const [kindProposal]),
    ]);
    final decisions = <String, String>{for (final f in (await _followStore(profileId)).follows) ...f.decisions};
    return [
      for (final e in sent)
        {
          'id': e.id,
          'owner': e.tagValues('p').firstOrNull ?? '',
          'createdAt': e.createdAt,
          'status': decisions[e.id] ?? 'pending',
          ...(jsonDecode(e.content) as Map).cast<String, Object?>(),
        },
    ];
  }

  bool _shouldBeOnline(ProfileInfo p) => p.stayOnline || p.id == _store.active?.id;

  Future<String> _address(String id) async {
    final known = _addresses[id];
    if (known != null) return known;
    final secrets = await _store.unlock(id);
    try {
      return _addresses[id] = await sharedDestinationAddress(secrets.i2pEncSeed, secrets.i2pSignSeed);
    } finally {
      secrets.wipe();
    }
  }

  Future<FileEventStore> _eventStore(String id) =>
      _stores[id] ??= FileEventStore.open(File('${_store.profileDir(id).path}/events.jsonl'));

  Future<void> _goOnline(ProfileInfo p) async {
    if (net.isWanted(p.id)) return;
    final secrets = await _store.unlock(p.id);
    final online = OnlineProfile(
      id: p.id,
      pubkey: p.pubkey,
      i2pEncSeed: Uint8List.fromList(secrets.i2pEncSeed),
      i2pSignSeed: Uint8List.fromList(secrets.i2pSignSeed),
      store: await _eventStore(p.id),
      policy: (e) => _rolePolicy(p.id, e),
      resolve: (sha) => _resolveSha(p.id, sha),
    );
    secrets.wipe();
    await net.setOnline(online);
  }

  /// Brings each profile's network presence in line with its settings.
  Future<void> _syncOnline() async {
    for (final p in _store.profiles) {
      if (_shouldBeOnline(p)) {
        await _goOnline(p);
      } else if (net.isWanted(p.id)) {
        await net.setOffline(p.id);
      }
    }
  }

  /// Signs an event as profile [id] and keeps it in that profile's relay.
  Future<NostrEvent> _publishLocal(String id, int kind, String content, [List<List<String>> tags = const []]) async {
    // A new version of a replaceable or addressable event must be strictly
    // newer than the one it replaces; same-second ties would otherwise be
    // settled by id and could keep the old version.
    var createdAt = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final probe = NostrEvent(id: '', pubkey: '', createdAt: 0, kind: kind, tags: tags, content: '', sig: '');
    if (probe.isReplaceable || probe.isAddressable) {
      final me = _store.profiles.firstWhere((p) => p.id == id).pubkey;
      final previous = await (await _eventStore(id)).query([
        NostrFilter(
          authors: [me],
          kinds: [kind],
          tags: probe.isAddressable
              ? {
                  'd': [probe.dTag],
                }
              : const {},
          limit: 1,
        ),
      ]);
      if (previous.isNotEmpty && previous.first.createdAt >= createdAt) createdAt = previous.first.createdAt + 1;
    }
    final e = NostrEvent.sign(
      secretKey: await _secretKey(id),
      kind: kind,
      content: content,
      tags: tags,
      createdAt: createdAt,
    );
    final node = net.nodeOf(id);
    if (node != null) {
      await node.relay.publishLocal(e);
    } else {
      await (await _eventStore(id)).add(e);
    }
    return e;
  }

  Future<Map<String, Object?>> _state() async {
    final lib = _store.active == null ? null : await _library(_activeId);
    final storage = <Map<String, Object?>>[];
    for (final path in _baseFolders) {
      final used = lib?.collections.where((c) => c.folder.startsWith(path)).fold<int>(0, (n, c) => n + c.size) ?? 0;
      storage.add({'path': path, 'used': used, 'free': await _freeBytes(path), 'isDefault': path == _defaultFolder});
    }
    return {
      ..._baseState(),
      'commons': {'id': Commons.id, 'name': Commons.name, 'description': Commons.description},
      'collections': [
        for (final c in lib?.collections ?? const <Collection>[])
          {
            ...c.toJson(),
            'files': [for (final f in c.files) _fileState(c, f)],
            'size': c.size,
          },
      ],
      'storage': storage,
      'previews': await _previews.available(),
      'subtitles': _subtitleState(),
      'following': [
        if (_store.active != null)
          for (final f in (await _followStore(_activeId)).follows)
            {
              ...f.toJson(),
              'error': f.error,
              'refreshing': f.refreshing,
              'waiting': f.outbox.length,
              'synced': {
                for (final x in (await _syncStore(_activeId)).items.where((x) => x.owner == f.pubkey))
                  x.collection: x.state(),
              },
            },
      ],
      'proposals': _store.active == null ? const [] : await _proposals(_activeId),
      'mySuggestions': _store.active == null ? const [] : await _mySuggestions(_activeId),
    };
  }

  Map<String, Object?> _baseState() => {
    'active': _store.active?.id,
    'profiles': [
      for (final p in _store.profiles)
        {
          ...p.toJson(),
          'npub': p.npub,
          'npubShort': p.npubShort,
          'i2p': _addresses[p.id] ?? '',
          'online': net.addressOf(p.id) != null,
          'arcaAddress': arcaAddress(p.npub, _addresses[p.id] ?? ''),
        },
    ],
    'net': {'state': net.state.name, 'error': net.error},
  };

  /// Handles one request; returns the new state, a result, or an error.
  Future<Map<String, Object?>> handle(String command, Map<String, Object?> args) async {
    try {
      switch (command) {
        case 'state':
          break;
        case 'create':
          final p = await _store.create(name: args['name'] as String?);
          await _address(p.id);
          await _syncOnline();
        case 'import':
          final p = await _store.importKey(args['key'] as String, name: args['name'] as String?);
          await _address(p.id);
          if (args['activate'] == true) await _store.setActive(p.id);
          await _syncOnline();
        case 'setActive':
          await _store.setActive(args['id'] as String);
          await _syncOnline();
        case 'rename':
          final p = await _store.rename(args['id'] as String, args['name'] as String);
          // A name change is the user acting, so the profile is published as
          // a Nostr kind 0 event in its own relay (docs/architecture.md, 3.2).
          await _publishLocal(p.id, Kind.profile, jsonEncode({'name': p.name}));
        case 'stayOnline':
          await _store.setStayOnline(args['id'] as String, args['on'] as bool);
          await _syncOnline();
        case 'delete':
          if (_store.profiles.length <= 1) {
            return {'error': 'This is the only profile on this device. Create or import another one first.'};
          }
          final id = args['id'] as String;
          _forgetKey(id);
          await net.setOffline(id);
          await (await _stores.remove(id))?.close();
          await _store.delete(id);
          _addresses.remove(id);
          await _syncOnline();
        case 'exportNsec':
          final secrets = await _store.unlock(args['id'] as String);
          try {
            return {'nsec': nsecEncode(secrets.secretKey)};
          } finally {
            secrets.wipe();
          }
        case 'netStart':
          net.start();
        case 'createCollection':
          final col = await (await _library(_activeId)).create(
            name: args['name'] as String,
            description: args['description'] as String? ?? '',
            folder: args['folder'] as String?,
            baseFolder: args['base'] as String? ?? _defaultFolder,
          );
          await _publishCollection(col);
          final st = await _state();
          return {...st, 'created': col.id};
        case 'addFiles':
          final lib = await _library(_activeId);
          final id = args['collection'] as String;
          await lib.addFiles(id, (args['paths'] as List).cast<String>());
          await _publishCollection(lib.byId(id));
          unawaited(_makePreviews());
          unawaited(_queueSubtitles());
        case 'updateCollection':
          final lib = await _library(_activeId);
          final id = args['collection'] as String;
          await lib.updateCollection(id, name: args['name'] as String?, description: args['description'] as String?);
          await _publishCollection(lib.byId(id));
        case 'updateFile':
          final lib = await _library(_activeId);
          final id = args['collection'] as String;
          await lib.updateFile(
            id,
            args['path'] as String,
            title: args['title'] as String?,
            description: args['description'] as String?,
            tags: (args['tags'] as List?)?.cast<String>(),
          );
          await _publishCollection(lib.byId(id));
        case 'removeFile':
          final lib = await _library(_activeId);
          final id = args['collection'] as String;
          await lib.removeFile(id, args['path'] as String, deleteFromDisk: args['delete'] == true);
          await _publishCollection(lib.byId(id));
        case 'removeCollection':
          await (await _library(_activeId)).removeCollection(args['collection'] as String);
        case 'addBaseFolder':
          final path = (args['path'] as String).replaceAll(RegExp(r'/+$'), '');
          if (!_baseFolders.contains(path)) _baseFolders.add(path);
          await _saveSettings();
        case 'setDefaultFolder':
          _defaultFolder = args['path'] as String;
          await _saveSettings();
        case 'removeBaseFolder':
          final path = args['path'] as String;
          if (_baseFolders.length <= 1) return {'error': 'Keep at least one storage folder.'};
          _baseFolders.remove(path);
          if (_defaultFolder == path) _defaultFolder = _baseFolders.first;
          await _saveSettings();
        case 'comments':
          return await _comments(args['target'] as String);
        case 'comment':
          final text = (args['content'] as String).trim();
          if (text.isEmpty) return {'error': 'Write something first.'};
          final target = args['target'] as String;
          await _publishLocal(_activeId, Kind.comment, text, [
            ['I', target],
            ['K', target.split(':').take(2).join(':')],
            ['i', target],
            ['k', target.split(':').take(2).join(':')],
          ]);
          return await _comments(target);
        case 'follow':
          final (pubkey, address) = parseArcaAddress(args['address'] as String);
          if (pubkey == _store.active!.pubkey) return {'error': 'That is your own address.'};
          final fs = await _followStore(_activeId);
          var f = fs.byPubkey(pubkey);
          if (f == null) {
            f = Follow(pubkey: pubkey, address: address);
            fs.follows.add(f);
            await fs.save();
          }
          _background(_refreshFollow(_activeId, f));
        case 'unfollow':
          final fs = await _followStore(_activeId);
          fs.follows.removeWhere((f) => f.pubkey == args['pubkey']);
          await fs.save();
        case 'refreshFollows':
          for (final f in (await _followStore(_activeId)).follows) {
            _background(_refreshFollow(_activeId, f));
          }
          _background(_foldIncoming(_activeId));
        case 'propose':
          final owner = args['owner'] as String;
          final fs = await _followStore(_activeId);
          final f = fs.byPubkey(owner);
          if (f == null) return {'error': 'You do not follow the owner of that collection.'};
          final m = f.collections[args['collection']];
          // Sent to the admin and every moderator; any of them may decide.
          final moderators = [
            for (final x in m?['moderators'] as List? ?? const [])
              if ((x as Map)['pubkey'] != _store.active!.pubkey) x.cast<String, Object?>(),
          ];
          final changes = <String, Object?>{
            if (args['title'] != null) 'title': args['title'],
            if (args['description'] != null) 'description': args['description'],
            if (args['tags'] != null) 'tags': args['tags'],
          };
          final e = await _publishLocal(
            _activeId,
            kindProposal,
            jsonEncode({
              'collection': args['collection'],
              'collectionName': args['collectionName'] ?? '',
              'path': args['path'],
              'sha256': args['sha256'],
              'changes': changes,
              'note': args['note'] ?? '',
              // The owner may not have our profile yet; the name travels with
              // the suggestion (signed by us, so only as trustworthy as we are).
              'fromName': _store.active!.name,
            }),
            [
              ['p', owner],
              for (final x in moderators) ['p', x['pubkey'] as String],
              ['a', '${Kind.arcaCollection}:$owner:${args['collection']}'],
              ['x', args['sha256'] as String],
            ],
          );
          final node = net.nodeOf(_activeId);
          if (node == null) return {'error': 'Your profile is not online on I2P, so the suggestion could not be sent.'};
          final targets = [
            f.address,
            for (final x in moderators) x['address'] as String? ?? '',
          ].where((a) => a.isNotEmpty);
          var delivered = false;
          String? refusal;
          final missed = <String>[];
          for (final to in targets) {
            final r = await node.publish(to, e, attempts: 2, timeout: const Duration(seconds: 20));
            if (r.accepted) {
              delivered = true;
            } else if (r.timedOut) {
              missed.add(to);
            } else {
              refusal ??= r.message;
            }
          }
          if (missed.isNotEmpty) {
            f.outbox.add({'event': e.toJson(), 'to': missed});
            await fs.save();
          }
          if (!delivered) {
            return {
              'error': refusal != null
                  ? 'Refused: $refusal'
                  : 'The owner did not answer. Try again when they are online.',
            };
          }
          return {...await _state(), 'sent': e.id};
        case 'decide':
          final id = args['id'] as String;
          final accept = args['accept'] as bool;
          final proposal = (await _proposals(_activeId)).where((p) => p['id'] == id).firstOrNull;
          if (proposal == null) return {'error': 'That suggestion is no longer pending.'};
          final me = _store.active!.pubkey;
          final owner = proposal['owner'] as String;
          final collection = proposal['collection'] as String;
          final address = '${Kind.arcaCollection}:$owner:$collection';
          final ch = (proposal['changes'] as Map).cast<String, Object?>();
          if (owner == me) {
            // The admin decides for its own collection.
            if (accept) {
              final lib = await _library(_activeId);
              final col = lib.byId(collection);
              final file = col.files.where((f) => f.path == proposal['path']).firstOrNull;
              if (file == null || file.sha256 != proposal['sha256']) {
                return {'error': 'The file changed or was removed since the suggestion was made.'};
              }
              await lib.updateFile(
                col.id,
                file.path,
                title: ch['title'] as String?,
                description: ch['description'] as String?,
                tags: (ch['tags'] as List?)?.cast<String>(),
              );
              await _publishCollection(col);
            }
            await _publishLocal(_activeId, Kind.reaction, accept ? '+' : '-', [
              ['e', id],
              ['p', proposal['from'] as String],
              ['a', address],
              ['k', '$kindProposal'],
            ]);
          } else {
            // A moderator decides: the change is signed as a moderator's
            // change and goes to the admin with the decision.
            final fs = await _followStore(_activeId);
            final f = fs.byPubkey(owner);
            if (f == null) return {'error': 'You do not follow the admin of that collection.'};
            if (accept) {
              final error = await _moderate(
                _activeId,
                f,
                collection,
                [
                  {'op': 'edit', 'path': proposal['path'], 'sha256': proposal['sha256'], ...ch},
                ],
                const [],
                acceptsProposal: id,
              );
              if (error != null) return {'error': error};
            }
            final r = await _publishLocal(_activeId, Kind.reaction, accept ? '+' : '-', [
              ['e', id],
              ['p', proposal['from'] as String],
              ['p', owner],
              ['a', address],
              ['k', '$kindProposal'],
            ]);
            f.decisions[id] = accept ? 'accepted' : 'rejected';
            final refused = await _deliver(_activeId, f, r, [f.address]);
            await fs.save();
            if (refused != null) return {'error': 'The admin refused the decision: $refused'};
          }
        case 'setModerators':
          final lib = await _library(_activeId);
          final col = lib.byId(args['collection'] as String);
          final mods = <Map<String, String>>[];
          for (final a in (args['addresses'] as List).cast<String>()) {
            final (pubkey, address) = parseArcaAddress(a);
            if (pubkey == _store.active!.pubkey) return {'error': 'You are the admin already.'};
            if (mods.every((m) => m['pubkey'] != pubkey)) mods.add({'pubkey': pubkey, 'address': address});
          }
          await lib.setModerators(col.id, mods);
          await _publishCollection(col);
        case 'sync':
          final fs = await _followStore(_activeId);
          final f = fs.byPubkey(args['owner'] as String);
          if (f == null) return {'error': 'You do not follow the owner of that collection.'};
          final collection = args['collection'] as String;
          final store = await _syncStore(_activeId);
          if (args['on'] == false) {
            // Stops keeping it in sync; the files already copied stay.
            store.items.removeWhere((x) => x.owner == f.pubkey && x.collection == collection);
            await store.save();
          } else {
            final s = await _syncEntry(_activeId, f, collection);
            _background(_syncOne(_activeId, f, s));
          }
        case 'moderate':
          final fs = await _followStore(_activeId);
          final f = fs.byPubkey(args['owner'] as String);
          if (f == null) return {'error': 'You do not follow the admin of that collection.'};
          final error = await _moderate(_activeId, f, args['collection'] as String, [
            for (final o in args['ops'] as List? ?? const []) (o as Map).cast<String, Object?>(),
          ], (args['addPaths'] as List?)?.cast<String>() ?? const []);
          if (error != null) return {'error': error};
        case 'downloadModel':
          final m = modelById(args['id'] as String?);
          if (m == null) return {'error': 'Unknown model'};
          unawaited(_downloadModel(m));
        case 'stopDownload':
          _stopDownloads.add(args['id'] as String);
        case 'deleteModel':
          final m = modelById(args['id'] as String?);
          if (m == null) return {'error': 'Unknown model'};
          if (_whisperModel == m.id) {
            _whisperModel = null;
            _transcriber.cancel();
            await _saveSettings();
          }
          await _models.delete(m);
        case 'selectModel':
          final m = modelById(args['id'] as String?);
          if (m == null || !_models.installed(m)) return {'error': 'Download the model first'};
          _whisperModel = m.id;
          await _saveSettings();
          unawaited(_queueSubtitles());
        case 'autoSubtitles':
          _autoSubtitles = args['on'] as bool;
          await _saveSettings();
          if (_autoSubtitles) {
            unawaited(_queueSubtitles());
          } else {
            _subtitleQueue.clear();
          }
        case 'setCover':
          await (await _library(_activeId)).setCover(args['collection'] as String, args['path'] as String?);
        case 'makeSubtitles':
          if (!_transcriber.available()) return {'error': 'Subtitles cannot be made on this device'};
          final col = (await _library(_activeId)).byId(args['collection'] as String);
          final f = col.files.firstWhere((f) => f.path == args['path']);
          await _subtitles.clearFailure(f.sha256);
          _redo.add(f.sha256);
          // Asked for by hand: goes ahead of the automatic ones.
          final rest = Map.of(_subtitleQueue)..remove(f.sha256);
          _subtitleQueue
            ..clear()
            ..[f.sha256] = ('${col.folder}/${f.path}', f.name)
            ..addAll(rest);
          // No model yet: fetch the one that suits this device first; the
          // file waits in the queue and starts when it is in.
          if (_readyModel == null) {
            final m = modelById(_whisperModel) ?? modelById(recommendedModel())!;
            _whisperModel = m.id;
            await _saveSettings();
            unawaited(_downloadModel(m));
          } else {
            unawaited(_runSubtitles());
          }
        case 'stopSubtitles':
          // Stops whatever this file is waiting on: the model download,
          // its place in the queue, or the running job.
          final sha = args['sha256'] as String?;
          if (sha != null && _subtitleSha != sha) {
            _subtitleQueue.remove(sha);
            _redo.remove(sha);
            if (_subtitleQueue.isEmpty) _stopDownloads.addAll(_downloads.keys);
          } else {
            _transcriber.cancel();
          }
        case 'hashFile':
          final (sha256, sha1, size) = await hashFile(File(args['path'] as String));
          return {'sha256': sha256, 'sha1': sha1, 'size': size};
        default:
          return {'error': 'unknown command $command'};
      }
      // Files may have been added or removed: rebuild what is shared.
      _shaPaths.clear();
      return await _state();
    } on FormatException catch (e) {
      return {'error': e.message};
    } on LibraryException catch (e) {
      return {'error': e.message};
    } on FileSystemException catch (e) {
      return {'error': '${e.message}: ${e.path ?? ''}'};
    } on ProfileException catch (e) {
      return {'error': e.message};
    } on VaultException catch (e) {
      return {'error': e.message};
    }
  }

  Future<void> close() async {
    // Background passes (copies, folding) stop at their next step; wait
    // for them so nothing writes after close.
    _closing = true;
    await Future.wait(_tasks.toList()).timeout(const Duration(seconds: 30), onTimeout: () => const []);
    for (final id in _keys.keys.toList()) {
      _forgetKey(id);
    }
    await net.stop();
    for (final s in _stores.values) {
      await (await s).close();
    }
  }
}

/// Entry point of the core isolate. [args] is `[SendPort toUi, String dataDir]`,
/// optionally followed by `bool startNetwork` (false in tests) and the
/// default storage folder.
/// Requests arrive as `[int id, String command, Map args]`; replies go back
/// as `[int id, Map result]`. The first message sent is the isolate's own
/// SendPort, then `[0, state]` once the store is open; later unsolicited
/// state updates (network changes) arrive as `[-1, state]`.
Future<void> coreIsolateMain(List<Object?> args) async {
  final toUi = args[0] as SendPort;
  final inbox = ReceivePort();
  toUi.send(inbox.sendPort);
  final CoreService core;
  try {
    core = await CoreService.open(
      args[1] as String,
      startNetwork: args.length < 3 || args[2] != false,
      defaultBaseFolder: args.length > 3 ? args[3] as String? : null,
    );
  } catch (e) {
    toUi.send([
      0,
      {'error': 'Could not open Arca data: $e'},
    ]);
    return;
  }
  core.onPush = (state) => toUi.send([-1, state]);
  toUi.send([0, await core.handle('state', const {})]);
  // Requests run concurrently, so a slow network call (a suggestion waiting
  // for the owner's relay) does not hold up the rest of the app.
  await for (final msg in inbox) {
    final m = msg as List<Object?>;
    unawaited(
      core.handle(m[1] as String, (m[2] as Map).cast<String, Object?>()).then((result) => toUi.send([m[0], result])),
    );
  }
}
