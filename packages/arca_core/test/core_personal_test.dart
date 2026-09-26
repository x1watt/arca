// What a profile keeps for itself, and the device settings behind Settings:
// search and opened-file history, likes, the space for others' notes, and
// the sharing hours.
import 'dart:io';

import 'package:arca_core/arca_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  setUp(() async => tmp = await Directory.systemTemp.createTemp('arca_personal'));
  tearDown(() async => tmp.delete(recursive: true));

  Future<CoreService> open() => CoreService.open(
    '${tmp.path}/data',
    cost: VaultCost.test,
    backend: LoopbackBackend(LoopbackNetwork()),
    startNetwork: false,
    defaultBaseFolder: '${tmp.path}/Arca',
  );

  test('search and opened-file history: newest first, no repeats, cleared, kept across restarts', () async {
    var c = await open();
    for (final q in ['maps', 'radio', 'maps']) {
      await c.handle('rememberSearch', {'query': q});
    }
    await c.handle('opened', {'sha256': 'a' * 64, 'name': 'talk.webm', 'mime': 'video/webm'});
    await c.handle('opened', {'sha256': 'b' * 64, 'name': 'notes.pdf', 'mime': 'application/pdf'});
    await c.handle('opened', {'sha256': 'a' * 64, 'name': 'talk.webm', 'mime': 'video/webm'});
    var s = await c.handle('state', {});
    expect([for (final e in s['searches'] as List) (e as Map)['query']], ['maps', 'radio']);
    expect([for (final e in s['opened'] as List) (e as Map)['name']], ['talk.webm', 'notes.pdf']);
    await c.close();

    c = await open();
    s = await c.handle('state', {});
    expect((s['searches'] as List), hasLength(2), reason: 'kept across a restart');
    s = await c.handle('clearSearches', {});
    expect(s['searches'], isEmpty);
    s = await c.handle('clearOpened', {});
    expect(s['opened'], isEmpty);
    await c.close();
  });

  test('likes are signed kind 17 events on the file, withdrawn with a deletion, kept across restarts', () async {
    var c = await open();
    final sha = 'c' * 64;
    var s = await c.handle('like', {'sha256': sha, 'on': true});
    expect(s['liked'], [sha]);
    await c.close();
    c = await open();
    s = await c.handle('state', {});
    expect(s['liked'], [sha], reason: 'read back from the profile\'s relay');
    s = await c.handle('like', {'sha256': sha, 'on': false});
    expect(s['liked'], isEmpty);
    await c.close();
    c = await open();
    expect((await c.handle('state', {}))['liked'], isEmpty, reason: 'the deletion is kept too');
    await c.close();
  });

  test('space for others\' notes: the oldest of others\' events go first, the owner\'s stay', () async {
    final store = await FileEventStore.open(File('${tmp.path}/events.jsonl'));
    final me = generateSecretKey(), other = generateSecretKey();
    for (var i = 0; i < 20; i++) {
      await store.add(NostrEvent.sign(secretKey: other, kind: 1, content: 'note $i ${'x' * 200}', createdAt: 1000 + i));
    }
    await store.add(NostrEvent.sign(secretKey: me, kind: 1, content: 'mine', createdAt: 999));
    final dropped = await store.prune(2000, (e) => e.pubkey != toHex(publicKeyOf(me)));
    expect(dropped, greaterThan(10));
    final left = await store.query([NostrFilter()]);
    expect(left.any((e) => e.content == 'mine'), isTrue);
    expect(
      left.where((e) => e.content.startsWith('note')).map((e) => e.createdAt).reduce((a, b) => a < b ? a : b),
      greaterThan(1000 + dropped - 1),
      reason: 'the oldest went first',
    );
    await store.close();
    // The file was rewritten: a reopened store holds the same.
    final again = await FileEventStore.open(File('${tmp.path}/events.jsonl'));
    expect(await again.count(), left.length);
    await again.close();
  });

  test('sharing hours: outside the window sharing stops; settings survive restarts', () async {
    var c = await open();
    final h = DateTime.now().hour;
    var s = await c.handle('setSharing', {'hoursFrom': (h + 1) % 24, 'hoursTo': (h + 2) % 24});
    expect((s['sharing'] as Map)['allowed'], isFalse);
    s = await c.handle('setSharing', {'hoursFrom': h, 'hoursTo': (h + 1) % 24});
    expect((s['sharing'] as Map)['allowed'], isTrue);
    await c.handle('setAskFolder', {'on': true});
    await c.handle('setNoteSpace', {'bytes': 1024 * 1024});
    await c.close();
    c = await open();
    s = await c.handle('state', {});
    expect(s['askFolder'], isTrue);
    expect(s['noteSpace'], 1024 * 1024);
    expect((s['sharing'] as Map)['hoursFrom'], h);
    await c.close();
  });
}
