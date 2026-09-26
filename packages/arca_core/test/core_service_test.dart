import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:arca_core/arca_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('arca_core'));
  tearDown(() async => dir.delete(recursive: true));

  test('first open creates a profile with an I2P address', () async {
    final core = await CoreService.open(dir.path, cost: VaultCost.test, startNetwork: false);
    final s = await core.handle('state', {});
    final profiles = s['profiles'] as List;
    expect(profiles.length, 1);
    final p = profiles.single as Map;
    expect(s['active'], p['id']);
    expect(p['npub'] as String, startsWith('npub1'));
    expect(p['i2p'] as String, matches(RegExp(r'^[a-z2-7]{52}\.b32\.i2p$')));
  });

  test('import, switch, export and delete through requests', () async {
    final core = await CoreService.open(dir.path, cost: VaultCost.test, startNetwork: false);
    final sk = generateSecretKey();
    var s = await core.handle('import', {'key': nsecEncode(sk), 'name': 'Club', 'activate': true});
    final club = (s['profiles'] as List).cast<Map>().firstWhere((p) => p['name'] == 'Club');
    expect(s['active'], club['id']);
    expect((await core.handle('import', {'key': nsecEncode(sk)}))['error'], contains('already'));
    expect((await core.handle('exportNsec', {'id': club['id']}))['nsec'], nsecEncode(sk));
    s = await core.handle('delete', {'id': club['id']});
    expect((s['profiles'] as List).length, 1);
    final last = ((s['profiles'] as List).single as Map)['id'];
    expect((await core.handle('delete', {'id': last}))['error'], contains('only profile'));
  });

  test('online profiles get a relay on the network, and reach each other', () async {
    final net = LoopbackNetwork();
    final core = await CoreService.open(
      dir.path,
      cost: VaultCost.test,
      backend: LoopbackBackend(net),
      startNetwork: false,
    );
    await core.net.start();
    var s = await core.handle('state', {});
    final first = (s['profiles'] as List).single as Map;
    expect(first['online'], isTrue, reason: 'the active profile is online');
    expect((s['net'] as Map)['state'], 'up');

    s = await core.handle('create', {'name': 'Offline one'});
    final second = (s['profiles'] as List).cast<Map>().firstWhere((p) => p['name'] == 'Offline one');
    expect(second['online'], isFalse, reason: 'neither active nor set to stay online');
    s = await core.handle('stayOnline', {'id': second['id'], 'on': true});
    expect((s['profiles'] as List).cast<Map>().firstWhere((p) => p['id'] == second['id'])['online'], isTrue);

    // Renaming writes a kind 0 event; the other profile can fetch it over the network.
    await core.handle('rename', {'id': first['id'], 'name': 'Max'});
    final a = core.net.nodeOf(first['id'] as String)!;
    final b = core.net.nodeOf(second['id'] as String)!;
    final got = await b.query(a.address, [
      const NostrFilter(kinds: [0]),
    ]);
    expect(got.single.content, '{"name":"Max"}');
    expect(got.single.verify(), isTrue);

    // The owner's relay refuses unrelated events from others.
    final stranger = NostrEvent.sign(secretKey: generateSecretKey(), kind: 1, content: 'spam');
    final r = await b.publish(a.address, stranger, attempts: 1);
    expect(r.accepted, isFalse);
    expect(r.message, startsWith('restricted'));

    s = await core.handle('stayOnline', {'id': second['id'], 'on': false});
    expect(core.net.nodeOf(second['id'] as String), isNull);
    await core.close();
  });

  test('starts in Arca Commons, creates collections, adds files, and comments', () async {
    final core = await CoreService.open(
      dir.path,
      cost: VaultCost.test,
      startNetwork: false,
      defaultBaseFolder: '${dir.path}/Arca',
    );
    var s = await core.handle('state', {});
    expect((s['commons'] as Map)['name'], 'Arca Commons');
    expect(s['collections'], isEmpty);
    expect(((s['storage'] as List).single as Map)['path'], '${dir.path}/Arca');

    s = await core.handle('createCollection', {'name': 'Manuals', 'description': 'Radio manuals'});
    final id = s['created'] as String;
    final src = File('${dir.path}/guide.pdf')..writeAsStringSync('%PDF-1.4 hello');
    s = await core.handle('addFiles', {
      'collection': id,
      'paths': [src.path],
    });
    final col = (s['collections'] as List).single as Map;
    expect(col['circle'], 'commons');
    final file = (col['files'] as List).single as Map;
    expect(file['mime'], 'application/pdf');
    expect(File('${col['folder']}/guide.pdf').existsSync(), isTrue);

    // The collection head is a signed addressable event in the profile's relay.
    final profile = ((s['profiles'] as List).single as Map)['id'] as String;
    final store = await FileEventStore.open(File('${dir.path}/profiles/$profile/events.jsonl'));
    final heads = await store.query([
      const NostrFilter(kinds: [Kind.arcaCollection]),
    ]);
    expect(heads.single.dTag, id);
    expect(heads.single.verify(), isTrue);
    await store.close();

    final target = 'arca:sha256:${file['sha256']}';
    final c = await core.handle('comment', {'target': target, 'content': 'Great scan'});
    final comments = c['comments'] as List;
    expect((comments.single as Map)['content'], 'Great scan');
    expect((comments.single as Map)['mine'], isTrue);
    expect((await core.handle('comment', {'target': target, 'content': '  '}))['error'], isNotNull);

    final h = await core.handle('hashFile', {'path': src.path});
    expect(h['sha256'], file['sha256']);
    await core.close();
  });

  test('a failed start is reported and can be retried', () async {
    final core = await CoreService.open(
      dir.path,
      cost: VaultCost.test,
      backend: LoopbackBackend(LoopbackNetwork(), startOk: false),
      startNetwork: false,
    );
    await core.net.start();
    final s = await core.handle('state', {});
    expect((s['net'] as Map)['state'], 'failed');
    expect((s['net'] as Map)['error'], isNotNull);
    await core.close();
  });

  test('runs in its own isolate', () async {
    final fromCore = ReceivePort();
    await Isolate.spawn(coreIsolateMain, [fromCore.sendPort, dir.path, false]);
    final it = StreamIterator(fromCore);
    expect(await it.moveNext(), isTrue);
    final toCore = it.current as SendPort;
    expect(await it.moveNext(), isTrue);
    final ready = it.current as List;
    expect(ready[0], 0);
    expect(((ready[1] as Map)['profiles'] as List).length, 1);
    toCore.send([
      7,
      'create',
      {'name': 'Second'},
    ]);
    expect(await it.moveNext(), isTrue);
    final reply = it.current as List;
    expect(reply[0], 7);
    expect(((reply[1] as Map)['profiles'] as List).length, 2);
    fromCore.close();
  });
}
