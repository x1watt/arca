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
    this.waiting = const [],
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

  /// Files (by SHA-256) waiting for their turn or for the model.
  final List<String> waiting;
  final String? currentSha;
  final String currentName;

  /// -1 while the audio is read, then 0 to 100.
  final int progress;

  bool get hasModel => models.any((m) => m.id == selected && m.installed);

  /// The model being fetched, if any.
  SpeechModelView? get downloading =>
      models.where((m) => m.downloading).firstOrNull;

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
      waiting: (m['waiting'] as List?)?.cast<String>() ?? const [],
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

/// One of a collection's moderators, as its admin lists them.
class ModeratorView {
  const ModeratorView(this.pubkey, this.address);
  final String pubkey;
  final String address;

  factory ModeratorView.fromMap(Map m) =>
      ModeratorView(m['pubkey'] as String, m['address'] as String? ?? '');
}

/// This profile's copy of someone else's collection, and the running pass.
class SyncView {
  const SyncView({
    required this.folder,
    required this.running,
    required this.done,
    required this.total,
    required this.bytes,
    required this.totalBytes,
    this.error,
    this.syncedAt,
  });
  final String folder;
  final bool running;
  final int done;
  final int total;
  final int bytes;
  final int totalBytes;
  final String? error;
  final int? syncedAt;

  factory SyncView.fromMap(Map m) => SyncView(
    folder: m['folder'] as String,
    running: m['running'] as bool? ?? false,
    done: m['done'] as int? ?? 0,
    total: m['total'] as int? ?? 0,
    bytes: m['bytes'] as int? ?? 0,
    totalBytes: m['totalBytes'] as int? ?? 0,
    error: m['error'] as String?,
    syncedAt: m['syncedAt'] as int?,
  );
}

class RemoteCollection {
  const RemoteCollection(
    this.id,
    this.name,
    this.description,
    this.files,
    this.updatedAt, {
    this.moderators = const [],
    this.sync,
    this.complete = true,
  });
  final String id;
  final String name;
  final String description;
  final List<RemoteFile> files;
  final int updatedAt;
  final List<ModeratorView> moderators;

  /// Set when this profile keeps a copy.
  final SyncView? sync;

  /// False when the collection is too large to list in one event.
  final bool complete;

  bool isModerator(String pubkey) => moderators.any((m) => m.pubkey == pubkey);

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
          moderators: [
            for (final x in c['moderators'] as List? ?? const [])
              ModeratorView.fromMap(x as Map),
          ],
          sync: switch ((m['synced'] as Map?)?[c['id']]) {
            final Map x => SyncView.fromMap(x),
            _ => null,
          },
          complete: c['complete'] as bool? ?? true,
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
    required this.owner,
  });
  final String id;

  /// The collection's admin; not this profile when it reviews as a
  /// moderator.
  final String owner;
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
    owner: m['owner'] as String? ?? '',
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
    this.cover,
    this.moderators = const [],
  });

  final String id;
  final String name;
  final String description;
  final String circle;

  /// People appointed to change this collection besides its admin.
  final List<ModeratorView> moderators;
  final String folder;
  final int createdAt;
  final int size;
  final List<FileView> files;

  /// Path of the file the owner picked to show for the collection.
  final String? cover;

  FileView? get coverFile =>
      cover == null ? null : files.where((f) => f.path == cover).firstOrNull;

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
      cover: m['cover'] as String?,
      moderators: [
        for (final x in m['moderators'] as List? ?? const [])
          ModeratorView.fromMap(x as Map),
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

/// One partition of the testnet's corpus, as this profile keeps it.
class PartitionView {
  const PartitionView({
    required this.index,
    required this.bytes,
    required this.keep,
    required this.packing,
    required this.packed,
    required this.declared,
    required this.provenToday,
    required this.dueToday,
    required this.copies,
  });
  final int index;
  final int bytes;
  final bool keep;

  /// 0 to 1 while packing, else null.
  final double? packing;
  final bool packed;
  final bool declared;
  final bool provenToday;

  /// Whether a proof is due today (from the day after it was declared).
  final bool dueToday;

  /// Keepers keeping it, this profile included.
  final int copies;

  factory PartitionView.fromMap(Map m) => PartitionView(
    index: m['index'] as int,
    bytes: m['bytes'] as int,
    keep: m['keep'] as bool,
    packing: (m['packing'] as num?)?.toDouble(),
    packed: m['packed'] as bool,
    declared: m['declared'] as bool,
    provenToday: m['provenToday'] as bool,
    dueToday: m['dueToday'] as bool? ?? false,
    copies: m['copies'] as int,
  );
}

/// The active profile's place on the test chain: its wallet, what it keeps
/// and its circle's pool.
class ChainView {
  const ChainView({
    required this.invite,
    required this.name,
    required this.founder,
    required this.height,
    required this.day,
    required this.nextDayAt,
    required this.dayLength,
    required this.behind,
    required this.peers,
    required this.balance,
    required this.pending,
    required this.mining,
    required this.paused,
    required this.standing,
    required this.syncScore,
    required this.corpusReady,
    required this.corpusBuilding,
    required this.corpusError,
    required this.corpusFiles,
    required this.corpusPresent,
    required this.partitions,
    required this.circleName,
    required this.pool,
    required this.isAdmin,
    required this.claimed,
    required this.light,
    required this.passPrice,
    required this.freeAllowance,
    required this.memberScore,
    required this.passEndsAt,
  });
  final String invite;
  final String name;
  final bool founder;
  final int height;
  final int day;

  /// When the next day starts (milliseconds since the epoch), and a day's
  /// length in seconds.
  final int nextDayAt;
  final int dayLength;
  final bool behind;
  final int peers;

  /// In grains (1 marca = 100,000,000 grains).
  final int balance;
  final int pending;
  final bool mining;

  /// Why making blocks and preparing copies wait: 'charging', 'network',
  /// or null.
  final String? paused;
  final int standing;
  final int syncScore;
  final bool corpusReady;
  final bool corpusBuilding;
  final String? corpusError;
  final int corpusFiles;
  final int corpusPresent;
  final List<PartitionView> partitions;
  final String circleName;
  final int pool;
  final bool isAdmin;
  final int claimed;

  /// This device follows the chain lightly (headers and proven reads) and
  /// keeps no files.
  final bool light;

  /// How the circle is read: the price of a 24-hour pass (0: none sold),
  /// the free bytes per reader per day, the sync score for free access,
  /// and when this profile's pass ends (null: none).
  final int passPrice;
  final int freeAllowance;
  final int memberScore;
  final int? passEndsAt;

  static ChainView? fromMap(Map? m) {
    if (m == null) return null;
    final corpus = m['corpus'] as Map;
    final circle = m['circle'] as Map?;
    final reading = m['reading'] as Map?;
    return ChainView(
      invite: m['invite'] as String,
      name: m['name'] as String,
      founder: m['founder'] as bool,
      height: m['height'] as int,
      day: m['day'] as int,
      nextDayAt: m['nextDayAt'] as int,
      dayLength: m['dayLength'] as int,
      behind: m['behind'] as bool,
      peers: m['peers'] as int,
      balance: m['balance'] as int,
      pending: m['pending'] as int,
      mining: m['mining'] as bool,
      paused: m['paused'] as String?,
      standing: m['standing'] as int,
      syncScore: m['syncScore'] as int,
      corpusReady: corpus['ready'] as bool,
      corpusBuilding: corpus['building'] as bool,
      corpusError: corpus['error'] as String?,
      corpusFiles: corpus['files'] as int,
      corpusPresent: corpus['present'] as int,
      partitions: [
        for (final p in m['partitions'] as List)
          PartitionView.fromMap(p as Map),
      ],
      circleName: circle?['name'] as String? ?? '',
      pool: circle?['pool'] as int? ?? 0,
      isAdmin: circle?['admin'] as bool? ?? false,
      claimed: circle?['claimed'] as int? ?? 0,
      light: m['light'] as bool? ?? false,
      passPrice: reading?['passPrice'] as int? ?? 0,
      freeAllowance: reading?['freeAllowance'] as int? ?? 0,
      memberScore: reading?['memberScore'] as int? ?? 0,
      passEndsAt: (reading?['myPass'] as Map?)?['endsAt'] as int?,
    );
  }
}

/// When this device shares with others and does the chain's heavy work.
class SharingView {
  const SharingView({
    this.onlyUnmetered = true,
    this.onlyCharging = true,
    this.uploadLimit = 2 * 1024 * 1024,
    this.freeShare = 20,
    this.allowed = true,
  });
  final bool onlyUnmetered;
  final bool onlyCharging;

  /// Bytes per second.
  final int uploadLimit;

  /// Percent of a day's upload free readers may use.
  final int freeShare;

  /// Whether the limits allow sharing right now.
  final bool allowed;

  factory SharingView.fromMap(Map? m) => m == null
      ? const SharingView()
      : SharingView(
          onlyUnmetered: m['onlyUnmetered'] as bool? ?? true,
          onlyCharging: m['onlyCharging'] as bool? ?? true,
          uploadLimit: m['uploadLimit'] as int? ?? 2 * 1024 * 1024,
          freeShare: (m['freeShare'] as num?)?.toInt() ?? 20,
          allowed: m['allowed'] as bool? ?? true,
        );
}

/// "1,234.5 marcas" from grains, without trailing zeros.
String formatMarcas(int grains) {
  final whole = grains ~/ 100000000;
  final frac = (grains % 100000000)
      .toString()
      .padLeft(8, '0')
      .replaceFirst(RegExp(r'0+$'), '');
  final digits = whole.toString();
  final grouped = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) grouped.write(',');
    grouped.write(digits[i]);
  }
  return '${grouped.toString()}${frac.isEmpty ? '' : '.$frac'} marcas';
}

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
    this.chain,
    this.chainPending = false,
    this.chainError,
    this.sharing = const SharingView(),
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

  /// The active profile on the test chain; null when it takes no part.
  final ChainView? chain;

  /// A test network was started or joined and waits for the network.
  final bool chainPending;

  /// Why the test network could not start on this device, if it could not.
  final String? chainError;
  final SharingView sharing;

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
      chain: ChainView.fromMap(result['chain'] as Map?),
      chainPending: result['chainPending'] as bool? ?? false,
      chainError: result['chainError'] as String?,
      sharing: SharingView.fromMap(result['sharing'] as Map?),
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

  /// Stops subtitles for [sha256] (its download, its place in the queue or
  /// its running job), or the running job when null.
  Future<String?> stopSubtitles([String? sha256]) =>
      _change('stopSubtitles', {'sha256': ?sha256});

  Future<String?> setCover(String collection, String? path) =>
      _change('setCover', {'collection': collection, 'path': path});

  // Working on collections together

  Future<String?> setModerators(String collection, List<String> addresses) =>
      _change('setModerators', {
        'collection': collection,
        'addresses': addresses,
      });

  /// Starts or stops keeping a copy of someone else's collection.
  Future<String?> sync(String owner, String collection, {bool on = true}) =>
      _change('sync', {'owner': owner, 'collection': collection, 'on': on});

  /// As a moderator: sign changes to someone else's collection.
  Future<String?> moderate(
    String owner,
    String collection, {
    List<Map<String, Object?>> ops = const [],
    List<String> addPaths = const [],
  }) => _change('moderate', {
    'owner': owner,
    'collection': collection,
    'ops': ops,
    'addPaths': addPaths,
  });

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

  // The test chain and the wallet.

  Future<String?> chainStart(String collection) =>
      _change('chainStart', {'collection': collection});
  Future<String?> chainJoin(String invite) =>
      _change('chainJoin', {'invite': invite});
  Future<String?> chainLeave() => _change('chainLeave');
  Future<String?> chainSend(String to, String amount) =>
      _change('chainSend', {'to': to, 'amount': amount});
  Future<String?> chainKeep(int partition, bool keep) =>
      _change('chainKeep', {'partition': partition, 'keep': keep});
  Future<String?> chainMining(bool on) => _change('chainMining', {'on': on});

  /// When this device shares (Settings).
  Future<String?> setSharing({
    bool? onlyUnmetered,
    bool? onlyCharging,
    int? uploadLimit,
    int? freeShare,
  }) => _change('setSharing', {
    'onlyUnmetered': ?onlyUnmetered,
    'onlyCharging': ?onlyCharging,
    'uploadLimit': ?uploadLimit,
    'freeShare': ?freeShare,
  });

  /// The device's power and connection, from [PowerWatch].
  Future<void> setPower({required bool charging, required bool unmetered}) =>
      _call('chainPower', {'charging': charging, 'unmetered': unmetered});
  Future<String?> chainPayout() => _change('chainPayout');
  Future<String?> chainLight(bool on) => _change('chainLight', {'on': on});
  Future<String?> chainBuyPass() => _change('chainBuyPass');

  /// The admin's reading settings; [passPrice] in marcas as typed.
  Future<String?> chainReading({
    String? passPrice,
    int? freeAllowance,
    int? memberScore,
  }) => _change('chainReading', {
    'passPrice': ?passPrice,
    'freeAllowance': ?freeAllowance,
    'memberScore': ?memberScore,
  });
  Future<String?> chainClaim() => _change('chainClaim');

  /// SHA-256 and SHA-1 of a file on disk, computed on the core isolate.
  Future<(String, String)?> hashFile(String path) async {
    final r = await _call('hashFile', {'path': path});
    if (r['error'] != null) return null;
    return (r['sha256'] as String, r['sha1'] as String);
  }
}
