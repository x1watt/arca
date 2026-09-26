// A collection's index as everyone else sees it (docs/architecture.md, 4.7):
// the admin's head event (kind 30780) plus the changes its admin and
// moderators signed since (kind 4782), replayed in order. Changes to
// different files merge; a change to a file that has changed since is
// skipped; changes by anyone else are ignored.

import 'dart:convert';

import '../nostr/event.dart';

/// Provisional kind for a signed change to a collection: add, remove or
/// edit files. Regular event, tagged with the collection (`a`), its admin
/// (`p`) and the suggestion it accepts (`e`), if any.
const kindCollectionChange = 4782;

/// How many applied change ids the head keeps, so followers know what is
/// already folded into it.
const maxAppliedIds = 500;

class IndexFile {
  IndexFile({
    required this.path,
    required this.sha256,
    required this.size,
    required this.mime,
    this.title = '',
    this.description = '',
    this.tags = const [],
    List<String>? providers,
  }) : providers = providers ?? [];

  final String path;
  final String sha256;
  final int size;
  final String mime;
  String title;
  String description;
  List<String> tags;

  /// Addresses known to hold the bytes, besides the admin and moderators.
  final List<String> providers;

  Map<String, Object?> toJson() => {
    'path': path,
    'sha256': sha256,
    'size': size,
    'mime': mime,
    'title': title,
    'description': description,
    'tags': tags,
    if (providers.isNotEmpty) 'providers': providers,
  };

  factory IndexFile.fromJson(Map m) => IndexFile(
    path: m['path'] as String,
    sha256: m['sha256'] as String,
    size: (m['size'] as num?)?.toInt() ?? 0,
    mime: m['mime'] as String? ?? 'application/octet-stream',
    title: m['title'] as String? ?? '',
    description: m['description'] as String? ?? '',
    tags: [for (final t in m['tags'] as List? ?? const []) t as String],
    providers: [for (final p in m['providers'] as List? ?? const []) p as String],
  );
}

/// A moderator as the admin lists them: key and I2P address.
class Moderator {
  const Moderator(this.pubkey, this.address);
  final String pubkey;
  final String address;
}

class CollectionIndex {
  CollectionIndex({
    required this.admin,
    required this.id,
    required this.name,
    this.description = '',
    List<Moderator>? moderators,
    Map<String, IndexFile>? files,
    Set<String>? applied,
    this.headAt = 0,
    this.complete = true,
  }) : moderators = moderators ?? [],
       files = files ?? {},
       applied = applied ?? {};

  final String admin;
  final String id;
  String name;
  String description;
  final List<Moderator> moderators;

  /// Files by path.
  final Map<String, IndexFile> files;

  /// Change ids already part of this index.
  final Set<String> applied;
  final int headAt;

  /// False when the head was too big to list its files.
  final bool complete;

  String get address => '30780:$admin:$id';

  bool isModerator(String pubkey) => moderators.any((m) => m.pubkey == pubkey);

  /// Whether [pubkey] may change this collection.
  bool mayChange(String pubkey) => pubkey == admin || isModerator(pubkey);

  /// Reads the admin's head event; null when it is not a collection head.
  static CollectionIndex? fromHead(NostrEvent head) {
    if (head.kind != Kind.arcaCollection) return null;
    final Map m;
    try {
      m = jsonDecode(head.content) as Map;
    } catch (_) {
      return null;
    }
    final index = CollectionIndex(
      admin: head.pubkey,
      id: head.dTag,
      name: m['name'] as String? ?? '',
      description: m['description'] as String? ?? '',
      headAt: head.createdAt,
      complete: m['files'] is List,
      moderators: [
        for (final t in head.tags)
          if (t.length >= 3 && t[0] == 'role' && t[2] == 'moderator') Moderator(t[1], t.length > 3 ? t[3] : ''),
      ],
      applied: {
        for (final t in head.tags)
          if (t.length >= 2 && t[0] == 'applied') t[1],
      },
    );
    for (final f in m['files'] as List? ?? const []) {
      final file = IndexFile.fromJson(f as Map);
      index.files[file.path] = file;
    }
    return index;
  }

  /// The operations in a change event; empty when it is not one.
  static List<Map<String, Object?>> operations(NostrEvent change) {
    if (change.kind != kindCollectionChange) return const [];
    try {
      final m = jsonDecode(change.content) as Map;
      return [for (final o in m['ops'] as List) (o as Map).cast<String, Object?>()];
    } catch (_) {
      return const [];
    }
  }

  /// Whether [change] is addressed to this collection.
  bool concerns(NostrEvent change) => change.tagValues('a').contains(address);

  /// Replays [changes] that concern this collection, are signed by its
  /// admin or a moderator, and are not folded in yet, oldest first.
  /// Returns the ids of the changes applied.
  List<String> fold(Iterable<NostrEvent> changes) {
    final todo = changes.where((c) => concerns(c) && !applied.contains(c.id) && mayChange(c.pubkey)).toList()
      ..sort((a, b) => a.createdAt != b.createdAt ? a.createdAt.compareTo(b.createdAt) : a.id.compareTo(b.id));
    final done = <String>[];
    for (final c in todo) {
      for (final op in operations(c)) {
        apply(op);
      }
      applied.add(c.id);
      done.add(c.id);
    }
    return done;
  }

  /// Applies one operation; returns false when it does not fit the index
  /// as it stands (the file changed or is gone), which leaves it unchanged.
  bool apply(Map<String, Object?> op) {
    final path = op['path'] as String?;
    final sha = op['sha256'] as String?;
    if (path == null || sha == null) return false;
    final current = files[path];
    switch (op['op']) {
      case 'add':
        if (current != null && current.sha256 != sha) return false;
        final file = IndexFile.fromJson(op);
        if (current != null) file.providers.addAll(current.providers.where((p) => !file.providers.contains(p)));
        files[path] = file;
        return true;
      case 'remove':
        if (current == null || current.sha256 != sha) return false;
        files.remove(path);
        return true;
      case 'edit':
        if (current == null || current.sha256 != sha) return false;
        if (op['title'] case final String t) current.title = t;
        if (op['description'] case final String d) current.description = d;
        if (op['tags'] case final List t) current.tags = t.cast<String>().toList();
        return true;
    }
    return false;
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'admin': admin,
    'name': name,
    'description': description,
    'moderators': [
      for (final m in moderators) {'pubkey': m.pubkey, 'address': m.address},
    ],
    'files': [for (final f in files.values) f.toJson()],
    'complete': complete,
    'updatedAt': headAt,
  };
}
