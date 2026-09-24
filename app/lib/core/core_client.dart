// The UI side of the core isolate (docs/architecture.md, 7). The core owns
// keys, vaults, storage and the network; the UI sends it requests and
// renders the state it returns. Nothing here blocks the UI isolate.

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:arca_core/arca_core.dart' show coreIsolateMain;
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// A profile as the UI sees it: public details only.
class ProfileView {
  const ProfileView({
    required this.id,
    required this.name,
    required this.pubkey,
    required this.npub,
    required this.npubShort,
    required this.i2pAddress,
    required this.stayOnline,
    required this.online,
    required this.arcaAddress,
  });

  final String id;
  final String name;

  /// Nostr public key, hex.
  final String pubkey;
  final String npub;
  final String npubShort;
  final String i2pAddress;
  final bool stayOnline;

  /// Answering on the network right now, with its own address and relay.
  final bool online;

  /// `arca:npub...@....b32.i2p`, shared so others can follow this profile.
  final String arcaAddress;

  String get initials {
    final words = name.split(' ').where((w) => w.isNotEmpty).take(2);
    final s = words.map((w) => w[0].toUpperCase()).join();
    return s.isEmpty ? '?' : s;
  }

  factory ProfileView.fromMap(Map m) => ProfileView(
    id: m['id'] as String,
    name: m['name'] as String,
    pubkey: m['pubkey'] as String,
    npub: m['npub'] as String,
    npubShort: m['npubShort'] as String,
    i2pAddress: m['i2p'] as String,
    stayOnline: m['stayOnline'] as bool,
    online: m['online'] as bool? ?? false,
    arcaAddress: m['arcaAddress'] as String? ?? '',
  );
}

/// A circle; for now only the built-in Arca Commons.
class CircleView {
  const CircleView(this.id, this.name, this.description);
  final String id;
  final String name;
  final String description;
}

class FileView {
  const FileView({
    required this.collectionId,
    required this.collectionName,
    required this.folder,
    required this.path,
    required this.size,
    required this.sha256,
    required this.sha1,
    required this.mime,
    required this.addedAt,
    required this.title,
    required this.description,
    required this.tags,
    this.still,
    this.animated,
    this.subtitles,
    this.subtitleLanguage,
    this.subtitleError,
    this.subtitleMachine = false,
  });

  final String collectionId;
  final String collectionName;
  final String folder;

  /// Path inside the collection, forward slashes.
  final String path;
  final int size;
  final String sha256;
  final String sha1;
  final String mime;
  final int addedAt;
  final String title;
  final String description;
  final List<String> tags;

  /// Preview pictures made on this device: a still frame and an animated GIF.
  final String? still;
  final String? animated;

  /// SubRip file made on this device by speech recognition, the language
  /// it detected, or why it could not be made.
  final String? subtitles;
  final String? subtitleLanguage;
  final String? subtitleError;

  /// Whether those subtitles were made here by speech recognition (as
  /// opposed to a subtitle file that came with the video).
  final bool subtitleMachine;

  String get name => path.split('/').last;
  String get displayTitle => title.isNotEmpty ? title : name;
  String get absolutePath => '$folder/$path';

  /// NIP-73 identifier used for comments and reactions on this file.
  String get target => 'arca:sha256:$sha256';

  factory FileView.fromMap(
    Map m,
    String collectionId,
    String collectionName,
    String folder,
  ) => FileView(
    collectionId: collectionId,
    collectionName: collectionName,
    folder: folder,
    path: m['path'] as String,
    size: m['size'] as int,
    sha256: m['sha256'] as String,
    sha1: m['sha1'] as String? ?? '',
    mime: m['mime'] as String,
    addedAt: m['addedAt'] as int,
    title: m['title'] as String? ?? '',
    description: m['description'] as String? ?? '',
    tags: (m['tags'] as List?)?.cast<String>() ?? const [],
    still: m['still'] as String?,
    animated: m['animated'] as String?,
    subtitles: m['subtitles'] as String?,
    subtitleLanguage: m['subtitleLanguage'] as String?,
    subtitleError: m['subtitleError'] as String?,
    subtitleMachine: m['subtitleMachine'] as bool? ?? false,
  );
}

/// A speech model for subtitles and how far its download got.
class SpeechModelView {
  const SpeechModelView({
    required this.id,
    required this.label,
    required this.detail,
    required this.bytes,
    required this.installed,
    required this.downloading,
    required this.received,
    this.error,
  });
  final String id;
  final String label;
  final String detail;
  final int bytes;
  final bool installed;
  final bool downloading;
  final int received;
  final String? error;

  factory SpeechModelView.fromMap(Map m) => SpeechModelView(
    id: m['id'] as String,
    label: m['label'] as String,
    detail: m['detail'] as String,
    bytes: m['bytes'] as int,
    installed: m['installed'] as bool,
    downloading: m['downloading'] as bool,
    received: m['received'] as int? ?? 0,
    error: m['error'] as String?,
  );
}

/// Subtitle making on this device: models, settings and the running job.
class SubtitleStatus {
  const SubtitleStatus({
    this.available = false,
    this.recommended = '',
    this.selected,
    this.auto = true,
    this.models = const [],
    this.queued = 0,
    this.currentSha,
    this.currentName = '',
    this.progress = 0,
  });
  final bool available;
  final String recommended;
  final String? selected;
  final bool auto;
  final List<SpeechModelView> models;
  final int queued;
  final String? currentSha;
  final String currentName;

  /// -1 while the audio is read, then 0 to 100.
  final int progress;

  bool get hasModel => models.any((m) => m.id == selected && m.installed);

  factory SubtitleStatus.fromMap(Map? m) {
    if (m == null) return const SubtitleStatus();
    final current = m['current'] as Map?;
    return SubtitleStatus(
      available: m['available'] as bool? ?? false,
      recommended: m['recommended'] as String? ?? '',
      selected: m['selected'] as String?,
      auto: m['auto'] as bool? ?? true,
      models: [
        for (final x in m['models'] as List? ?? const [])
          SpeechModelView.fromMap(x as Map),
      ],
      queued: m['queued'] as int? ?? 0,
      currentSha: current?['sha256'] as String?,
      currentName: current?['name'] as String? ?? '',
      progress: current?['progress'] as int? ?? 0,
    );
  }
}

/// A file in someone else's collection, as their relay describes it.
class RemoteFile {
  const RemoteFile(
    this.path,
    this.size,
    this.sha256,
    this.mime,
    this.title,
    this.description,
    this.tags,
  );
  final String path;
  final int size;
  final String sha256;
  final String mime;
  final String title;
  final String description;
  final List<String> tags;

  String get name => path.split('/').last;
  String get displayTitle => title.isNotEmpty ? title : name;

  factory RemoteFile.fromMap(Map m) => RemoteFile(
    m['path'] as String,
    m['size'] as int? ?? 0,
    m['sha256'] as String? ?? '',
    m['mime'] as String? ?? 'application/octet-stream',
    m['title'] as String? ?? '',
    m['description'] as String? ?? '',
    (m['tags'] as List?)?.cast<String>() ?? const [],
  );
}

class RemoteCollection {
  const RemoteCollection(
    this.id,
    this.name,
    this.description,
    this.files,
    this.updatedAt,
  );
  final String id;
  final String name;
  final String description;
  final List<RemoteFile> files;
  final int updatedAt;

  int get size => files.fold(0, (n, f) => n + f.size);
}

/// Someone this profile follows, with what their relay last told us.
class FollowView {
  const FollowView({
    required this.pubkey,
    required this.address,
    required this.name,
    required this.collections,
    required this.decisions,
    required this.fetchedAt,
    required this.error,
    required this.refreshing,
  });
  final String pubkey;
  final String address;
  final String name;
  final List<RemoteCollection> collections;

  /// Suggestion id to 'accepted' or 'rejected'.
  final Map<String, String> decisions;
  final int? fetchedAt;
  final String? error;
  final bool refreshing;

  String get displayName =>
      name.isNotEmpty ? name : '${pubkey.substring(0, 8)}...';

  factory FollowView.fromMap(Map m) => FollowView(
    pubkey: m['pubkey'] as String,
    address: m['address'] as String,
    name: m['name'] as String? ?? '',
    collections: [
      for (final c in (m['collections'] as Map? ?? {}).values)
        RemoteCollection(
          (c as Map)['id'] as String,
          c['name'] as String? ?? '',
          c['description'] as String? ?? '',
          [
            for (final f in c['files'] as List? ?? const [])
              RemoteFile.fromMap(f as Map),
          ],
          c['updatedAt'] as int? ?? 0,
        ),
    ],
    decisions: (m['decisions'] as Map? ?? {}).cast<String, String>(),
    fetchedAt: m['fetchedAt'] as int?,
    error: m['error'] as String?,
    refreshing: m['refreshing'] as bool? ?? false,
  );
}

/// A change someone suggested for one of this profile's files.
class ProposalView {
  const ProposalView({
    required this.id,
    required this.fromName,
    required this.fromNpub,
    required this.createdAt,
    required this.collectionId,
    required this.path,
    required this.sha256,
    required this.changes,
    required this.note,
  });
  final String id;
  final String fromName;
  final String fromNpub;
  final int createdAt;
  final String collectionId;
  final String path;
  final String sha256;
  final Map<String, Object?> changes;
  final String note;

  String get from => fromName.isNotEmpty
      ? fromName
      : '${fromNpub.substring(0, 12)}...${fromNpub.substring(fromNpub.length - 4)}';

  factory ProposalView.fromMap(Map m) => ProposalView(
    id: m['id'] as String,
    fromName: m['fromName'] as String? ?? '',
    fromNpub: m['fromNpub'] as String,
    createdAt: m['createdAt'] as int,
    collectionId: m['collection'] as String,
    path: m['path'] as String,
    sha256: m['sha256'] as String,
    changes: (m['changes'] as Map).cast<String, Object?>(),
    note: m['note'] as String? ?? '',
  );
}

/// A suggestion this profile sent to someone else, with its status.
class MySuggestion {
  const MySuggestion(
    this.id,
    this.owner,
    this.collectionId,
    this.path,
    this.status,
    this.createdAt,
    this.changes,
  );
  final String id;
  final String owner;
  final String collectionId;
  final String path;

  /// 'pending', 'accepted' or 'rejected'.
  final String status;
  final int createdAt;
  final Map<String, Object?> changes;

  factory MySuggestion.fromMap(Map m) => MySuggestion(
    m['id'] as String,
    m['owner'] as String,
    m['collection'] as String,
    m['path'] as String,
    m['status'] as String,
    m['createdAt'] as int,
    (m['changes'] as Map).cast<String, Object?>(),
  );
}

class CollectionView {
  const CollectionView({
    required this.id,
    required this.name,
    required this.description,
    required this.circle,
    required this.folder,
    required this.createdAt,
    required this.size,
    required this.files,
  });

  final String id;
  final String name;
  final String description;
  final String circle;
  final String folder;
  final int createdAt;
  final int size;
  final List<FileView> files;

  factory CollectionView.fromMap(Map m) {
    final id = m['id'] as String,
        name = m['name'] as String,
        folder = m['folder'] as String;
    return CollectionView(
      id: id,
      name: name,
      description: m['description'] as String? ?? '',
      circle: m['circle'] as String,
      folder: folder,
      createdAt: m['createdAt'] as int,
      size: m['size'] as int,
      files: [
        for (final f in m['files'] as List)
          FileView.fromMap(f as Map, id, name, folder),
      ],
    );
  }
}

class StorageFolder {
  const StorageFolder(this.path, this.used, this.free, this.isDefault);
  final String path;
  final int used;
  final int? free;
  final bool isDefault;
}

class CommentView {
  const CommentView(
    this.id,
    this.name,
    this.npub,
    this.content,
    this.createdAt,
    this.mine,
  );
  final String id;
  final String name;
  final String npub;
  final String content;
  final int createdAt;
  final bool mine;

  String get author => name.isNotEmpty
      ? name
      : '${npub.substring(0, 12)}...${npub.substring(npub.length - 4)}';
}

/// The I2P node: off, starting, up or failed.
enum NetStatus { off, starting, up, failed }

class CoreState {
  const CoreState(
    this.profiles,
    this.activeId, {
    this.net = NetStatus.off,
    this.netError,
    this.commons = const CircleView('commons', 'Arca Commons', ''),
    this.collections = const [],
    this.storage = const [],
    this.following = const [],
    this.proposals = const [],
    this.mySuggestions = const [],
    this.previewsAvailable = false,
    this.subtitles = const SubtitleStatus(),
  });
  final List<ProfileView> profiles;
  final String? activeId;
  final NetStatus net;
  final String? netError;
  final CircleView commons;
  final List<CollectionView> collections;
  final List<StorageFolder> storage;
  final List<FollowView> following;
  final List<ProposalView> proposals;
  final List<MySuggestion> mySuggestions;

  /// Whether this device can make video previews (ffmpeg is installed).
  final bool previewsAvailable;
  final SubtitleStatus subtitles;

  List<ProposalView> proposalsFor(String collectionId) =>
      proposals.where((p) => p.collectionId == collectionId).toList();

  FollowView? follow(String pubkey) =>
      following.where((f) => f.pubkey == pubkey).firstOrNull;

  ProfileView? get active =>
      profiles.where((p) => p.id == activeId).firstOrNull ??
      profiles.firstOrNull;

  List<ProfileView> get others =>
      profiles.where((p) => p.id != active?.id).toList();

  List<FileView> get allFiles => [for (final c in collections) ...c.files];

  int get librarySize => collections.fold(0, (n, c) => n + c.size);

  CollectionView? collection(String id) =>
      collections.where((c) => c.id == id).firstOrNull;
}

class Core {
  Core._();
  static final instance = Core._();

  /// Current state; null until the core has started.
  final state = ValueNotifier<CoreState?>(null);

  /// Set when the core could not start (for example an unreadable data folder).
  String? startError;

  SendPort? _toCore;
  final _pending = <int, Completer<Map>>{};
  var _nextId = 1;

  /// Where Arca keeps device data: ~/.local/share/arca on Linux, the app's
  /// support folder elsewhere.
  static Future<String> dataDir() async {
    if (Platform.isLinux) {
      final base =
          Platform.environment['XDG_DATA_HOME'] ??
          '${Platform.environment['HOME']}/.local/share';
      return '$base/arca';
    }
    return '${(await getApplicationSupportDirectory()).path}/arca';
  }

  /// The first storage folder: ~/Arca on Linux, the app's documents folder
  /// elsewhere.
  static Future<String> defaultStorageFolder() async {
    if (Platform.isLinux || Platform.isMacOS) {
      return '${Platform.environment['HOME']}/Arca';
    }
    return '${(await getApplicationDocumentsDirectory()).path}/Arca';
  }

  /// Spawns the core isolate and waits for its first state.
  Future<void> start() async {
    final fromCore = ReceivePort();
    final ready = Completer<void>();
    fromCore.listen((msg) {
      if (msg is SendPort) {
        _toCore = msg;
        return;
      }
      final m = msg as List;
      final id = m[0] as int;
      final result = m[1] as Map;
      if (id == -1) {
        _apply(result);
        return;
      }
      if (id == 0) {
        if (result['error'] != null) {
          startError = result['error'] as String;
        } else {
          _apply(result);
        }
        if (!ready.isCompleted) ready.complete();
        return;
      }
      _pending.remove(id)?.complete(result);
    });
    await Isolate.spawn(coreIsolateMain, [
      fromCore.sendPort,
      await dataDir(),
      true,
      await defaultStorageFolder(),
    ], debugName: 'arca-core');
    await ready.future;
  }

  void _apply(Map result) {
    if (result['profiles'] is! List) return;
    final net = result['net'] as Map?;
    final commons = result['commons'] as Map?;
    state.value = CoreState(
      [
        for (final p in result['profiles'] as List)
          ProfileView.fromMap(p as Map),
      ],
      result['active'] as String?,
      net: NetStatus.values.firstWhere(
        (n) => n.name == net?['state'],
        orElse: () => NetStatus.off,
      ),
      netError: net?['error'] as String?,
      commons: commons == null
          ? const CircleView('commons', 'Arca Commons', '')
          : CircleView(
              commons['id'] as String,
              commons['name'] as String,
              commons['description'] as String,
            ),
      collections: [
        for (final c in result['collections'] as List? ?? const [])
          CollectionView.fromMap(c as Map),
      ],
      storage: [
        for (final f in result['storage'] as List? ?? const [])
          StorageFolder(
            (f as Map)['path'] as String,
            f['used'] as int,
            f['free'] as int?,
            f['isDefault'] as bool,
          ),
      ],
      following: [
        for (final f in result['following'] as List? ?? const [])
          FollowView.fromMap(f as Map),
      ],
      proposals: [
        for (final p in result['proposals'] as List? ?? const [])
          ProposalView.fromMap(p as Map),
      ],
      mySuggestions: [
        for (final p in result['mySuggestions'] as List? ?? const [])
          MySuggestion.fromMap(p as Map),
      ],
      previewsAvailable: result['previews'] as bool? ?? false,
      subtitles: SubtitleStatus.fromMap(result['subtitles'] as Map?),
    );
  }

  Future<Map> _call(String command, [Map<String, Object?> args = const {}]) {
    final port = _toCore;
    if (port == null) return Future.value({'error': 'Arca is still starting'});
    final id = _nextId++;
    final c = Completer<Map>();
    _pending[id] = c;
    port.send([id, command, args]);
    return c.future;
  }

  /// Runs a state-changing command; returns an error message or null.
  Future<String?> _change(
    String command, [
    Map<String, Object?> args = const {},
  ]) async {
    final r = await _call(command, args);
    if (r['error'] != null) return r['error'] as String;
    _apply(r);
    return null;
  }

  // Profiles

  Future<String?> createProfile(String? name) =>
      _change('create', {'name': name});

  Future<String?> importProfile(
    String key, {
    String? name,
    bool activate = true,
  }) => _change('import', {'key': key, 'name': name, 'activate': activate});

  Future<String?> switchTo(String id) => _change('setActive', {'id': id});

  Future<String?> rename(String id, String name) =>
      _change('rename', {'id': id, 'name': name});

  Future<String?> setStayOnline(String id, bool on) =>
      _change('stayOnline', {'id': id, 'on': on});

  Future<String?> deleteProfile(String id) => _change('delete', {'id': id});

  /// The profile's nsec, or throws with the core's error message.
  Future<String> exportNsec(String id) async {
    final r = await _call('exportNsec', {'id': id});
    if (r['error'] != null) throw Exception(r['error']);
    return r['nsec'] as String;
  }

  // Network

  /// Starts (or retries) the I2P node.
  Future<String?> startNetwork() => _change('netStart');

  // Library

  /// Creates a collection; returns (error, new collection id).
  Future<(String?, String?)> createCollection(
    String name,
    String description, {
    String? folder,
  }) async {
    final r = await _call('createCollection', {
      'name': name,
      'description': description,
      'folder': folder,
    });
    if (r['error'] != null) return (r['error'] as String, null);
    _apply(r);
    return (null, r['created'] as String?);
  }

  Future<String?> addFiles(String collection, List<String> paths) =>
      _change('addFiles', {'collection': collection, 'paths': paths});

  Future<String?> updateCollection(
    String collection, {
    String? name,
    String? description,
  }) => _change('updateCollection', {
    'collection': collection,
    'name': name,
    'description': description,
  });

  Future<String?> updateFile(
    FileView f, {
    String? title,
    String? description,
    List<String>? tags,
  }) => _change('updateFile', {
    'collection': f.collectionId,
    'path': f.path,
    'title': title,
    'description': description,
    'tags': tags,
  });

  Future<String?> removeFile(FileView f, {bool deleteFromDisk = false}) =>
      _change('removeFile', {
        'collection': f.collectionId,
        'path': f.path,
        'delete': deleteFromDisk,
      });

  Future<String?> removeCollection(String collection) =>
      _change('removeCollection', {'collection': collection});

  Future<String?> addStorageFolder(String path) =>
      _change('addBaseFolder', {'path': path});

  Future<String?> setDefaultStorageFolder(String path) =>
      _change('setDefaultFolder', {'path': path});

  Future<String?> removeStorageFolder(String path) =>
      _change('removeBaseFolder', {'path': path});

  // Subtitles

  Future<String?> downloadModel(String id) =>
      _change('downloadModel', {'id': id});

  Future<String?> stopDownload(String id) =>
      _change('stopDownload', {'id': id});

  Future<String?> deleteModel(String id) => _change('deleteModel', {'id': id});

  Future<String?> selectModel(String id) => _change('selectModel', {'id': id});

  Future<String?> setAutoSubtitles(bool on) =>
      _change('autoSubtitles', {'on': on});

  Future<String?> makeSubtitles(FileView f) =>
      _change('makeSubtitles', {'collection': f.collectionId, 'path': f.path});

  Future<String?> stopSubtitles() => _change('stopSubtitles');

  // Following and suggestions

  Future<String?> follow(String address) =>
      _change('follow', {'address': address});

  Future<String?> unfollow(String pubkey) =>
      _change('unfollow', {'pubkey': pubkey});

  Future<String?> refreshFollows() => _change('refreshFollows');

  /// Sends suggested metadata for a file in someone else's collection.
  Future<String?> propose({
    required FollowView owner,
    required RemoteCollection collection,
    required RemoteFile file,
    String? title,
    String? description,
    List<String>? tags,
    String note = '',
  }) => _change('propose', {
    'owner': owner.pubkey,
    'collection': collection.id,
    'collectionName': collection.name,
    'path': file.path,
    'sha256': file.sha256,
    'title': title,
    'description': description,
    'tags': tags,
    'note': note,
  });

  Future<String?> decide(String proposalId, {required bool accept}) =>
      _change('decide', {'id': proposalId, 'accept': accept});

  // Comments

  List<CommentView> _commentsFrom(Map r) => [
    for (final c in r['comments'] as List? ?? const [])
      CommentView(
        (c as Map)['id'] as String,
        c['name'] as String,
        c['npub'] as String,
        c['content'] as String,
        c['createdAt'] as int,
        c['mine'] as bool,
      ),
  ];

  Future<List<CommentView>> comments(String target) async =>
      _commentsFrom(await _call('comments', {'target': target}));

  /// Publishes a comment; returns (error, comments after posting).
  Future<(String?, List<CommentView>)> comment(
    String target,
    String text,
  ) async {
    final r = await _call('comment', {'target': target, 'content': text});
    if (r['error'] != null) {
      return (r['error'] as String, const <CommentView>[]);
    }
    return (null, _commentsFrom(r));
  }

  /// SHA-256 and SHA-1 of a file on disk, computed on the core isolate.
  Future<(String, String)?> hashFile(String path) async {
    final r = await _call('hashFile', {'path': path});
    if (r['error'] != null) return null;
    return (r['sha256'] as String, r['sha1'] as String);
  }
}
