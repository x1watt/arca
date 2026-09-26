import 'dart:convert';

import 'package:arca_core/arca_core.dart';
import 'package:arca_core/src/library/collection_index.dart';
import 'package:test/test.dart';

void main() {
  final admin = generateSecretKey(), mod = generateSecretKey(), outsider = generateSecretKey();
  String pk(List<int> k) => toHex(publicKeyOf(k));
  final a = '30780:${pk(admin)}:c1';

  NostrEvent head({List<List<int>> mods = const [], List<String> applied = const [], int at = 100}) => NostrEvent.sign(
    secretKey: admin,
    kind: Kind.arcaCollection,
    createdAt: at,
    content: jsonEncode({
      'name': 'Clips',
      'description': '',
      'files': [
        {'path': 'a.txt', 'sha256': 'aa', 'size': 1, 'mime': 'text/plain', 'title': 'A'},
        {'path': 'b.txt', 'sha256': 'bb', 'size': 1, 'mime': 'text/plain', 'title': 'B'},
      ],
    }),
    tags: [
      ['d', 'c1'],
      for (final m in mods) ['role', pk(m), 'moderator', 'addr-${pk(m).substring(0, 4)}'],
      for (final id in applied) ['applied', id],
    ],
  );

  NostrEvent change(List<int> by, List<Map<String, Object?>> ops, int at) => NostrEvent.sign(
    secretKey: by,
    kind: kindCollectionChange,
    createdAt: at,
    content: jsonEncode({'ops': ops}),
    tags: [
      ['a', a],
      ['p', pk(admin)],
    ],
  );

  test('reads roles and files from the head', () {
    final i = CollectionIndex.fromHead(head(mods: [mod]))!;
    expect(i.admin, pk(admin));
    expect(i.files.keys, ['a.txt', 'b.txt']);
    expect(i.mayChange(pk(mod)), isTrue);
    expect(i.mayChange(pk(outsider)), isFalse);
    expect(i.moderators.single.address, startsWith('addr-'));
  });

  test('moderator changes merge in order; outsiders are ignored', () {
    final i = CollectionIndex.fromHead(head(mods: [mod]))!;
    final c1 = change(mod, [
      {'op': 'edit', 'path': 'a.txt', 'sha256': 'aa', 'title': 'Better A'},
    ], 110);
    final c2 = change(admin, [
      {'op': 'remove', 'path': 'b.txt', 'sha256': 'bb'},
      {
        'op': 'add',
        'path': 'c.txt',
        'sha256': 'cc',
        'size': 3,
        'mime': 'text/plain',
        'title': 'C',
        'providers': ['x'],
      },
    ], 105);
    final evil = change(outsider, [
      {'op': 'remove', 'path': 'a.txt', 'sha256': 'aa'},
    ], 120);
    final applied = i.fold([c1, evil, c2]);
    expect(applied, [c2.id, c1.id], reason: 'oldest first, outsider left out');
    expect(i.files.keys.toSet(), {'a.txt', 'c.txt'});
    expect(i.files['a.txt']!.title, 'Better A');
    expect(i.files['c.txt']!.providers, ['x']);
    // Folding again changes nothing.
    expect(i.fold([c1, c2]), isEmpty);
  });

  test('a change to a file that changed since is skipped', () {
    final i = CollectionIndex.fromHead(head(mods: [mod]))!;
    i.fold([
      change(mod, [
        {'op': 'edit', 'path': 'a.txt', 'sha256': 'OLD', 'title': 'Stale'},
      ], 110),
    ]);
    expect(i.files['a.txt']!.title, 'A');
  });

  test('changes already in the head, or by a removed moderator, do not apply', () {
    final c = change(mod, [
      {'op': 'edit', 'path': 'a.txt', 'sha256': 'aa', 'title': 'Once'},
    ], 110);
    final folded = CollectionIndex.fromHead(head(mods: [mod], applied: [c.id]))!;
    expect(folded.fold([c]), isEmpty);
    final removed = CollectionIndex.fromHead(head())!;
    expect(removed.fold([c]), isEmpty);
    expect(removed.files['a.txt']!.title, 'A');
  });
}
