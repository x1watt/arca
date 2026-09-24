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
import '../library/library.dart';
import '../library/previews.dart';
import '../library/subtitles.dart';
import '../nostr/event.dart';
import '../nostr/filter.dart';
import '../nostr/nip19.dart';
import '../profiles/profile_store.dart';
import '../profiles/vault.dart';
import '../relay/event_store.dart';
import 'network.dart';
import 'social.dart';

class CoreService {
  CoreService._(this._store, this.net, this._dataDir, this._defaultBase);

  final ProfileStore _store;
  final NetworkManager net;
  final String _dataDir;
  final String _defaultBase;

  /// Device settings: storage folders shared by all profiles.
  List<String> _baseFolders = [];
  String _defaultFolder = '';
  final _libraries = <String, Library>{};
  final _follows = <String, FollowStore>{};
  late final VideoPreviews _previews = VideoPreviews('$_dataDir/previews');

  // Subtitles (docs/architecture.md, 8.3): the chosen speech model, whether
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
  String? _subtitleSha;
  String _subtitleName = '';
  bool _subtitlesRunning = false;

  Future<FollowStore> _followStore(String profileId) async =>
      _follows[profileId] ??= await FollowStore.open(File('${_store.profileDir(profileId).path}/follows.json'));

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
  final _stores = <String, FileEventStore>{};

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
    );
    s = CoreService._(store, manager, dataDir, defaultBaseFolder ?? '${Platform.environment['HOME'] ?? dataDir}/Arca');
    await s._loadSettings();
    for (final p in store.profiles) {
      await s._address(p.id);
      if (s._shouldBeOnline(p)) await s._goOnline(p);
    }
    if (startNetwork) manager.start();
    unawaited(s._makePreviews());
    unawaited(s._queueSubtitles());
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

  Future<void> _saveSettings() => _settingsFile.writeAsString(jsonEncode({
    'baseFolders': _baseFolders,
    'defaultFolder': _defaultFolder,
    'whisperModel': _whisperModel,
    'autoSubtitles': _autoSubtitles,
  }));

  Future<Library> _library(String profileId) async =>
      _libraries[profileId] ??= await Library.open(File('${_store.profileDir(profileId).path}/collections.json'));

  String get _activeId => _store.active!.id;

  /// Publishes the collection's head as an addressable event in the owner's
  /// relay, so others can see what it holds once they can reach it.
  Future<void> _publishCollection(Collection col) async {
    final files = [
      for (final f in col.files) {'path': f.path, 'size': f.size, 'sha256': f.sha256, 'mime': f.mime, 'title': f.title},
    ];
    var content = jsonEncode({'name': col.name, 'description': col.description, 'files': files});
    if (utf8.encode(content).length > 28000) {
      // Too big for one event: publish the head and a count; the file list
      // travels with the collection itself once sharing over I2P lands.
      content = jsonEncode({'name': col.name, 'description': col.description, 'fileCount': files.length});
    }
    await _publishLocal(_activeId, Kind.arcaCollection, content, [
      ['d', col.id],
      ['title', col.name],
      ['circle', 'arca:circle:${col.circle}'],
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
      NostrFilter(kinds: const [Kind.comment], tags: {'I': [target]}),
    ]);
    final names = <String, String>{};
    for (final e in await store.query([NostrFilter(kinds: const [Kind.profile], authors: {for (final e in events) e.pubkey}.toList())])) {
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

  Map<String, Object?> _fileState(LibraryFile f) => {
    ...f.toJson(),
    if (_previews.hasStill(f.sha256)) 'still': _previews.still(f.sha256).path,
    if (_previews.hasAnimated(f.sha256)) 'animated': _previews.animated(f.sha256).path,
    if (_subtitles.has(f.sha256)) ...{
      'subtitles': _subtitles.srt(f.sha256).path,
      'subtitleLanguage': _subtitles.meta(f.sha256)['language'],
    },
    if (_subtitles.failure(f.sha256) case final why?) 'subtitleError': why,
  };

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
        if (_subtitles.has(f.sha256) || _subtitles.failed(f.sha256)) continue;
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
        if (_subtitles.has(sha)) continue;
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
          await _subtitles.saveMeta(sha, {
            'language': r.language,
            'model': model.id,
            'createdAt': DateTime.now().millisecondsSinceEpoch ~/ 1000,
          });
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
    } else if (_readyModel == null) {
      _whisperModel = m.id;
      await _saveSettings();
      await _queueSubtitles();
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
    if (_subtitleSha != null)
      'current': {'sha256': _subtitleSha, 'name': _subtitleName, 'progress': _transcriber.progress},
  };

  /// Fetches what a followed profile publishes: its name, its collections,
  /// and the decisions on suggestions we sent it. Runs in the background.
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
      final events = await node.query(f.address, [
        NostrFilter(authors: [f.pubkey], kinds: const [Kind.profile, Kind.arcaCollection]),
      ], timeout: const Duration(seconds: 60));
      final mine = await (await _eventStore(profileId)).query([
        NostrFilter(authors: [_store.profiles.firstWhere((p) => p.id == profileId).pubkey], kinds: const [kindProposal]),
      ]);
      final decisions = mine.isEmpty
          ? const <NostrEvent>[]
          : await node.query(f.address, [
              NostrFilter(authors: [f.pubkey], kinds: const [Kind.reaction], tags: {'e': [for (final e in mine) e.id]}),
            ], timeout: const Duration(seconds: 60));
      if (events.isEmpty && f.fetchedAt == null) {
        f.error = 'No answer yet. Their device may be offline, or their address is still spreading on I2P.';
      } else {
        for (final e in events) {
          if (e.kind == Kind.profile) {
            try {
              f.name = (jsonDecode(e.content) as Map)['name'] as String? ?? f.name;
            } catch (_) {}
          } else {
            try {
              final m = (jsonDecode(e.content) as Map).cast<String, Object?>();
              f.collections[e.dTag] = {...m, 'id': e.dTag, 'updatedAt': e.createdAt};
            } catch (_) {}
          }
        }
        for (final d in decisions) {
          final target = d.tagValues('e').firstOrNull;
          if (target != null) f.decisions[target] = d.content == '-' ? 'rejected' : 'accepted';
        }
        f.fetchedAt = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      }
    } catch (e) {
      f.error = '$e';
    } finally {
      f.refreshing = false;
      await (await _followStore(profileId)).save();
      _push();
    }
  }

  /// Suggestions others sent for this profile's files, not yet decided.
  Future<List<Map<String, Object?>>> _proposals(String profileId) async {
    final me = _store.profiles.firstWhere((p) => p.id == profileId).pubkey;
    final store = await _eventStore(profileId);
    final incoming = await store.query([
      NostrFilter(kinds: const [kindProposal], tags: {'p': [me]}),
    ]);
    if (incoming.isEmpty) return const [];
    final decided = {
      for (final r in await store.query([NostrFilter(authors: [me], kinds: const [Kind.reaction])]))
        ...r.tagValues('e'),
    };
    final names = <String, String>{};
    for (final e in await store.query([NostrFilter(kinds: const [Kind.profile], authors: {for (final e in incoming) e.pubkey}.toList())])) {
      try {
        names[e.pubkey] = (jsonDecode(e.content) as Map)['name'] as String;
      } catch (_) {}
    }
    return [
      for (final e in incoming.where((e) => !decided.contains(e.id) && e.pubkey != me))
        {
          'id': e.id,
          'from': e.pubkey,
          'fromName': names[e.pubkey] ?? ((jsonDecode(e.content) as Map)['fromName'] as String? ?? ''),
          'fromNpub': npubEncode(fromHex(e.pubkey)),
          'createdAt': e.createdAt,
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
    final decisions = <String, String>{
      for (final f in (await _followStore(profileId)).follows) ...f.decisions,
    };
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

  Future<FileEventStore> _eventStore(String id) async =>
      _stores[id] ??= await FileEventStore.open(File('${_store.profileDir(id).path}/events.jsonl'));

  Future<void> _goOnline(ProfileInfo p) async {
    if (net.isWanted(p.id)) return;
    final secrets = await _store.unlock(p.id);
    final online = OnlineProfile(
      id: p.id,
      pubkey: p.pubkey,
      i2pEncSeed: Uint8List.fromList(secrets.i2pEncSeed),
      i2pSignSeed: Uint8List.fromList(secrets.i2pSignSeed),
      store: await _eventStore(p.id),
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
          tags: probe.isAddressable ? {'d': [probe.dTag]} : const {},
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
          {...c.toJson(), 'files': [for (final f in c.files) _fileState(f)], 'size': c.size},
      ],
      'storage': storage,
      'previews': await _previews.available(),
      'subtitles': _subtitleState(),
      'following': [
        if (_store.active != null)
          for (final f in (await _followStore(_activeId)).follows)
            {...f.toJson(), 'error': f.error, 'refreshing': f.refreshing},
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
          await _stores.remove(id)?.close();
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
          unawaited(_refreshFollow(_activeId, f));
        case 'unfollow':
          final fs = await _followStore(_activeId);
          fs.follows.removeWhere((f) => f.pubkey == args['pubkey']);
          await fs.save();
        case 'refreshFollows':
          for (final f in (await _followStore(_activeId)).follows) {
            unawaited(_refreshFollow(_activeId, f));
          }
        case 'propose':
          final owner = args['owner'] as String;
          final f = (await _followStore(_activeId)).byPubkey(owner);
          if (f == null) return {'error': 'You do not follow the owner of that collection.'};
          final changes = <String, Object?>{
            if (args['title'] != null) 'title': args['title'],
            if (args['description'] != null) 'description': args['description'],
            if (args['tags'] != null) 'tags': args['tags'],
          };
          final e = await _publishLocal(_activeId, kindProposal, jsonEncode({
            'collection': args['collection'],
            'collectionName': args['collectionName'] ?? '',
            'path': args['path'],
            'sha256': args['sha256'],
            'changes': changes,
            'note': args['note'] ?? '',
            // The owner may not have our profile yet; the name travels with
            // the suggestion (signed by us, so only as trustworthy as we are).
            'fromName': _store.active!.name,
          }), [
            ['p', owner],
            ['a', '${Kind.arcaCollection}:$owner:${args['collection']}'],
            ['x', args['sha256'] as String],
          ]);
          final node = net.nodeOf(_activeId);
          if (node == null) return {'error': 'Your profile is not online on I2P, so the suggestion could not be sent.'};
          final r = await node.publish(f.address, e, attempts: 2, timeout: const Duration(seconds: 20));
          if (!r.accepted) {
            return {'error': r.timedOut ? 'The owner did not answer. Try again when they are online.' : 'Refused: ${r.message}'};
          }
          return {...await _state(), 'sent': e.id};
        case 'decide':
          final id = args['id'] as String;
          final accept = args['accept'] as bool;
          final proposal = (await _proposals(_activeId)).where((p) => p['id'] == id).firstOrNull;
          if (proposal == null) return {'error': 'That suggestion is no longer pending.'};
          if (accept) {
            final lib = await _library(_activeId);
            final col = lib.byId(proposal['collection'] as String);
            final file = col.files.where((f) => f.path == proposal['path']).firstOrNull;
            if (file == null || file.sha256 != proposal['sha256']) {
              return {'error': 'The file changed or was removed since the suggestion was made.'};
            }
            final ch = (proposal['changes'] as Map).cast<String, Object?>();
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
            ['k', '$kindProposal'],
          ]);
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
        case 'makeSubtitles':
          if (_readyModel == null) return {'error': 'Download a speech model in Settings first'};
          if (!_transcriber.available()) return {'error': 'Speech recognition is not available in this build'};
          final col = (await _library(_activeId)).byId(args['collection'] as String);
          final f = col.files.firstWhere((f) => f.path == args['path']);
          await _subtitles.clearFailure(f.sha256);
          final old = _subtitles.srt(f.sha256);
          if (await old.exists() && _subtitleSha != f.sha256) await old.delete();
          // Asked for by hand: goes ahead of the automatic ones.
          final rest = Map.of(_subtitleQueue)..remove(f.sha256);
          _subtitleQueue
            ..clear()
            ..[f.sha256] = ('${col.folder}/${f.path}', f.name)
            ..addAll(rest);
          unawaited(_runSubtitles());
        case 'stopSubtitles':
          _transcriber.cancel();
        case 'hashFile':
          final (sha256, sha1, size) = await hashFile(File(args['path'] as String));
          return {'sha256': sha256, 'sha1': sha1, 'size': size};
        default:
          return {'error': 'unknown command $command'};
      }
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
    for (final id in _keys.keys.toList()) {
      _forgetKey(id);
    }
    await net.stop();
    for (final s in _stores.values) {
      await s.close();
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
    toUi.send([0, {'error': 'Could not open Arca data: $e'}]);
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
