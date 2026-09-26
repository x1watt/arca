import 'dart:io';

import 'package:arca_core/arca_core.dart';
import 'package:arca_core/src/core/social.dart';
import 'package:test/test.dart';

Future<Map<String, Object?>> waitFor(CoreService c, bool Function(Map<String, Object?>) ok) async {
  for (var i = 0; i < 100; i++) {
    final s = await c.handle('state', {});
    if (ok(s)) return s;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  throw StateError('condition not reached');
}

void main() {
  late Directory tmp;
  setUp(() async => tmp = await Directory.systemTemp.createTemp('arca_social'));
  tearDown(() async => tmp.delete(recursive: true));

  test('Arca addresses round trip and explain mistakes', () {
    final npub = npubEncode(publicKeyOf(generateSecretKey()));
    final i2p = '${'a' * 52}.b32.i2p';
    final (pk, addr) = parseArcaAddress(arcaAddress(npub, i2p));
    expect(npubEncode(fromHex(pk)), npub);
    expect(addr, i2p);
    expect(() => parseArcaAddress('hello'), throwsFormatException);
    expect(() => parseArcaAddress('arca:$npub@example.com'), throwsFormatException);
  });

  test('follow someone, suggest a change, owner accepts, suggester sees it', () async {
    final net = LoopbackNetwork();
    Future<CoreService> open(String name) async {
      final c = await CoreService.open(
        '${tmp.path}/$name',
        cost: VaultCost.test,
        backend: LoopbackBackend(net),
        startNetwork: false,
        defaultBaseFolder: '${tmp.path}/$name/Arca',
      );
      await c.net.start();
      return c;
    }

    final alice = await open('alice'), bob = await open('bob');
    // Alice shares a file.
    var sa = await alice.handle('createCollection', {'name': 'Clips'});
    final colId = sa['created'] as String;
    final src = File('${tmp.path}/clip.txt')..writeAsStringSync('hello');
    sa = await alice.handle('addFiles', {
      'collection': colId,
      'paths': [src.path],
    });
    final aliceProfile = (sa['profiles'] as List).single as Map;
    final file = ((sa['collections'] as List).single as Map)['files'] as List;
    final sha = (file.single as Map)['sha256'] as String;

    // Bob follows Alice by her Arca address and sees her collection.
    await bob.handle('follow', {'address': aliceProfile['arcaAddress']});
    final sb = await waitFor(bob, (s) {
      final f = (s['following'] as List).cast<Map>();
      return f.isNotEmpty && (f.single['collections'] as Map).isNotEmpty;
    });
    final followed = (sb['following'] as List).single as Map;
    final remote = (followed['collections'] as Map)[colId] as Map;
    expect(remote['name'], 'Clips');
    expect(((remote['files'] as List).single as Map)['path'], 'clip.txt');

    // Bob suggests a better title; Alice's relay takes it.
    final sent = await bob.handle('propose', {
      'owner': aliceProfile['pubkey'],
      'collection': colId,
      'collectionName': 'Clips',
      'path': 'clip.txt',
      'sha256': sha,
      'title': 'Greeting clip',
      'tags': ['greeting'],
    });
    expect(sent['error'], isNull);

    sa = await alice.handle('state', {});
    final pending = (sa['proposals'] as List).cast<Map>();
    expect(pending.single['changes'], {
      'title': 'Greeting clip',
      'tags': ['greeting'],
    });

    // Alice accepts: the file changes and the suggestion leaves the queue.
    sa = await alice.handle('decide', {'id': pending.single['id'], 'accept': true});
    expect(sa['proposals'], isEmpty);
    final f2 = ((((sa['collections'] as List).single as Map)['files'] as List).single as Map);
    expect(f2['title'], 'Greeting clip');
    expect(f2['tags'], ['greeting']);

    // Bob refreshes and sees both the new title and the decision.
    await bob.handle('refreshFollows', {});
    final sb2 = await waitFor(bob, (s) {
      final f = ((s['following'] as List).single as Map);
      return (f['decisions'] as Map).isNotEmpty;
    });
    final f3 = (sb2['following'] as List).single as Map;
    expect((f3['decisions'] as Map).values.single, 'accepted');
    final rfile = ((((f3['collections'] as Map)[colId] as Map)['files'] as List).single as Map);
    expect(rfile['title'], 'Greeting clip');

    await alice.close();
    await bob.close();
  });

  test('a suggestion to someone offline fails with a clear message', () async {
    final net = LoopbackNetwork();
    final bob = await CoreService.open(
      '${tmp.path}/bob',
      cost: VaultCost.test,
      backend: LoopbackBackend(net),
      startNetwork: false,
      defaultBaseFolder: '${tmp.path}/Arca',
    );
    await bob.net.start();
    final npub = npubEncode(publicKeyOf(generateSecretKey()));
    await bob.handle('follow', {'address': arcaAddress(npub, '${'b' * 52}.b32.i2p')});
    final owner = ((await bob.handle('state', {}))['following'] as List).cast<Map>().single['pubkey'];
    final r = await bob.handle('propose', {
      'owner': owner,
      'collection': 'x',
      'path': 'y',
      'sha256': 'z' * 64,
      'title': 't',
    });
    expect(r['error'], contains('did not answer'));
    await bob.close();
  }, timeout: const Timeout(Duration(minutes: 3)));
}
