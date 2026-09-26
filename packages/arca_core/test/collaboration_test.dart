// Four instances on one in-process network: admin A, moderator M,
// follower F (keeps a copy and suggests), outsider O (tries to change what
// it may not).
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:arca_core/arca_core.dart';
import 'package:arca_core/src/library/collection_index.dart';
import 'package:test/test.dart';

Future<Map<String, Object?>> waitFor(CoreService c, bool Function(Map<String, Object?>) ok, {String what = ''}) async {
  Map<String, Object?> s = {};
  for (var i = 0; i < 300; i++) {
    s = await c.handle('state', {});
    if (ok(s)) return s;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  throw StateError('condition not reached: $what');
}

void main() {
  late Directory tmp;
  setUp(() async => tmp = await Directory.systemTemp.createTemp('arca_collab'));
  tearDown(() async => tmp.delete(recursive: true));

  test('sync, roles and approved changes across four instances', () async {
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

    final a = await open('admin'), m = await open('moderator'), f = await open('follower'), o = await open('outsider');
    Future<String> addressOf(CoreService c) async =>
        (((await c.handle('state', {}))['profiles'] as List).single as Map)['arcaAddress'] as String;
    Future<String> pubkeyOf(CoreService c) async =>
        (((await c.handle('state', {}))['profiles'] as List).single as Map)['pubkey'] as String;
    final aPub = await pubkeyOf(a);

    // A shares a collection: a text file and a 200 KB binary (several chunks).
    final text = File('${tmp.path}/a.txt')..writeAsStringSync('hello');
    final rng = Random(7);
    final bin = File('${tmp.path}/pic.bin')
      ..writeAsBytesSync(Uint8List.fromList(List.generate(200 * 1024, (_) => rng.nextInt(256))));
    var sa = await a.handle('createCollection', {'name': 'Clips'});
    final col = sa['created'] as String;
    await a.handle('addFiles', {
      'collection': col,
      'paths': [text.path, bin.path],
    });

    Map colOf(Map<String, Object?> s) =>
        ((s['following'] as List).cast<Map>().firstWhere((x) => x['pubkey'] == aPub)['collections'] as Map)[col] as Map;
    Map? syncOf(Map<String, Object?> s) =>
        ((s['following'] as List).cast<Map>().firstWhere((x) => x['pubkey'] == aPub)['synced'] as Map)[col] as Map?;
    List<Map> filesOf(Map<String, Object?> s) => (colOf(s)['files'] as List).cast<Map>();
    List<Map> adminFiles(Map<String, Object?> s) =>
        (((s['collections'] as List).single as Map)['files'] as List).cast<Map>();
    bool following(Map<String, Object?> s) {
      final list = (s['following'] as List).cast<Map>().where((x) => x['pubkey'] == aPub);
      return list.isNotEmpty && (list.single['collections'] as Map).containsKey(col);
    }

    // 1. F follows A and keeps a copy: byte-identical, with manifests.
    await f.handle('follow', {'address': await addressOf(a)});
    await waitFor(f, following, what: 'F sees the collection');
    await f.handle('sync', {'owner': aPub, 'collection': col});
    var sf = await waitFor(f, (s) {
      final x = syncOf(s);
      return x != null && x['running'] == false && x['done'] == 2;
    }, what: 'F copied both files');
    final folder = syncOf(sf)!['folder'] as String;
    expect(File('$folder/pic.bin').readAsBytesSync(), bin.readAsBytesSync());
    expect(File('$folder/a.txt').readAsStringSync(), 'hello');
    expect(jsonDecode(File('$folder/pic.arca.json').readAsStringSync())['sha256'], isNotEmpty);

    // 2. A adds and removes; F's copy follows.
    final c = File('${tmp.path}/c.txt')..writeAsStringSync('third');
    await a.handle('addFiles', {
      'collection': col,
      'paths': [c.path],
    });
    await a.handle('removeFile', {'collection': col, 'path': 'a.txt'});
    await f.handle('refreshFollows', {});
    sf = await waitFor(f, (s) {
      final x = syncOf(s);
      return x != null &&
          x['running'] == false &&
          (x['files'] as Map).containsKey('c.txt') &&
          !(x['files'] as Map).containsKey('a.txt');
    }, what: 'F copy updated');
    expect(File('$folder/c.txt').readAsStringSync(), 'third');
    expect(File('$folder/a.txt').existsSync(), isFalse, reason: 'removed from the collection, so from the copy');

    // 3. A appoints M; M edits a title; A folds it; F sees it.
    await a.handle('setModerators', {
      'collection': col,
      'addresses': [await addressOf(m)],
    });
    await m.handle('follow', {'address': await addressOf(a)});
    var sm = await waitFor(
      m,
      (s) => following(s) && (colOf(s)['moderators'] as List).isNotEmpty,
      what: 'M sees its role',
    );
    final pic = filesOf(sm).firstWhere((x) => x['path'] == 'pic.bin');
    var r = await m.handle('moderate', {
      'owner': aPub,
      'collection': col,
      'ops': [
        {'op': 'edit', 'path': 'pic.bin', 'sha256': pic['sha256'], 'title': 'A picture, retitled by M'},
      ],
    });
    expect(r['error'], isNull);
    await waitFor(
      a,
      (s) => adminFiles(s).any((x) => x['title'] == 'A picture, retitled by M'),
      what: 'A folded the edit',
    );
    await f.handle('refreshFollows', {});
    await waitFor(f, (s) => filesOf(s).any((x) => x['title'] == 'A picture, retitled by M'), what: 'F sees the edit');

    // 4. M adds a file; A fetches it from M; F's copy gets it.
    final extra = File('${tmp.path}/from-m.txt')..writeAsStringSync('added by the moderator');
    r = await m.handle('moderate', {
      'owner': aPub,
      'collection': col,
      'addPaths': [extra.path],
    });
    expect(r['error'], isNull);
    final sa2 = await waitFor(a, (s) => adminFiles(s).any((x) => x['path'] == 'from-m.txt'), what: 'A has M\'s file');
    final aFolder = ((sa2['collections'] as List).single as Map)['folder'] as String;
    expect(File('$aFolder/from-m.txt').readAsStringSync(), 'added by the moderator');
    await f.handle('refreshFollows', {});
    await waitFor(
      f,
      (s) => (syncOf(s)?['files'] as Map?)?.containsKey('from-m.txt') == true && syncOf(s)!['running'] == false,
      what: 'F copied M\'s file',
    );
    expect(File('$folder/from-m.txt').readAsStringSync(), 'added by the moderator');

    // 5. O is neither admin nor moderator: its client will not sign, and
    // A's relay refuses a change signed by hand.
    await o.handle('follow', {'address': await addressOf(a)});
    await waitFor(o, following, what: 'O sees the collection');
    r = await o.handle('moderate', {
      'owner': aPub,
      'collection': col,
      'ops': [
        {'op': 'remove', 'path': 'c.txt', 'sha256': 'x'},
      ],
    });
    expect(r['error'], contains('Only the admin and moderators'));
    final so = await o.handle('state', {});
    final oId = so['active'] as String;
    final nsec = (await o.handle('exportNsec', {'id': oId}))['nsec'] as String;
    final forged = NostrEvent.sign(
      secretKey: decodeEntity(nsec, 'nsec'),
      kind: kindCollectionChange,
      content: jsonEncode({
        'ops': [
          {'op': 'remove', 'path': 'c.txt', 'sha256': filesOf(so).firstWhere((x) => x['path'] == 'c.txt')['sha256']},
        ],
      }),
      tags: [
        ['a', '30780:$aPub:$col'],
        ['p', aPub],
      ],
    );
    final aI2p = (((await a.handle('state', {}))['profiles'] as List).single as Map)['i2p'] as String;
    final refused = await o.net.nodeOf(oId)!.publish(aI2p, forged, attempts: 1);
    expect(refused.accepted, isFalse);
    expect(refused.message, contains('restricted'));
    expect(adminFiles(await a.handle('state', {})).any((x) => x['path'] == 'c.txt'), isTrue);

    // 6. F suggests a title; M (a moderator) accepts; it reaches A's
    // collection and F's status and index.
    sf = await f.handle('state', {});
    final cFile = filesOf(sf).firstWhere((x) => x['path'] == 'c.txt');
    r = await f.handle('propose', {
      'owner': aPub,
      'collection': col,
      'collectionName': 'Clips',
      'path': 'c.txt',
      'sha256': cFile['sha256'],
      'title': 'Third file, better title',
      'note': 'clearer',
    });
    expect(r['error'], isNull);
    final suggestion = r['sent'] as String;
    sm = await waitFor(
      m,
      (s) => (s['proposals'] as List).any((p) => (p as Map)['id'] == suggestion),
      what: 'M got the suggestion',
    );
    r = await m.handle('decide', {'id': suggestion, 'accept': true});
    expect(r['error'], isNull);
    await waitFor(
      a,
      (s) => adminFiles(s).any((x) => x['title'] == 'Third file, better title'),
      what: 'A has the accepted title',
    );
    // Decided by M, so no longer pending for A either.
    expect(((await a.handle('state', {}))['proposals'] as List).where((p) => (p as Map)['id'] == suggestion), isEmpty);
    await f.handle('refreshFollows', {});
    sf = await waitFor(
      f,
      (s) =>
          (s['mySuggestions'] as List).any((x) => (x as Map)['id'] == suggestion && x['status'] == 'accepted') &&
          filesOf(s).any((x) => x['title'] == 'Third file, better title'),
      what: 'F sees accepted and the new title',
    );

    // F suggests again; A rejects; nothing changes.
    r = await f.handle('propose', {
      'owner': aPub,
      'collection': col,
      'path': 'c.txt',
      'sha256': cFile['sha256'],
      'title': 'A worse title',
    });
    final second = r['sent'] as String;
    await waitFor(a, (s) => (s['proposals'] as List).any((p) => (p as Map)['id'] == second), what: 'A got it');
    r = await a.handle('decide', {'id': second, 'accept': false});
    expect(r['error'], isNull);
    await f.handle('refreshFollows', {});
    await waitFor(
      f,
      (s) => (s['mySuggestions'] as List).any((x) => (x as Map)['id'] == second && x['status'] == 'rejected'),
      what: 'F sees rejected',
    );
    expect(adminFiles(await a.handle('state', {})).any((x) => x['title'] == 'A worse title'), isFalse);

    // 7. A removes M; M's next change is refused and changes nothing.
    await a.handle('setModerators', {'collection': col, 'addresses': <String>[]});
    await m.handle('refreshFollows', {});
    await waitFor(m, (s) => (colOf(s)['moderators'] as List).isEmpty, what: 'M sees it lost the role');
    r = await m.handle('moderate', {
      'owner': aPub,
      'collection': col,
      'ops': [
        {'op': 'edit', 'path': 'c.txt', 'sha256': cFile['sha256'], 'title': 'Too late'},
      ],
    });
    expect(r['error'], isNotNull);
    expect(adminFiles(await a.handle('state', {})).any((x) => x['title'] == 'Too late'), isFalse);

    for (final x in [a, m, f, o]) {
      await x.close();
    }
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('a collection too large for one message is paged, read and copied', () async {
    final net = LoopbackNetwork();
    Future<CoreService> open(String name) async {
      final c = await CoreService.open('${tmp.path}/$name',
          cost: VaultCost.test, backend: LoopbackBackend(net), startNetwork: false, defaultBaseFolder: '${tmp.path}/$name/Arca');
      await c.net.start();
      return c;
    }

    final a = await open('big-admin'), f = await open('big-follower');
    final src = await Directory('${tmp.path}/many').create();
    for (var i = 0; i < 600; i++) {
      File('${src.path}/file-$i.txt').writeAsStringSync('content of file $i');
    }
    final col = (await a.handle('createCollection', {'name': 'Many', 'folder': src.path}))['created'] as String;
    final sa = await a.handle('state', {});
    final aPub = (((sa['profiles'] as List).single as Map)['pubkey']) as String;
    await f.handle('follow', {'address': (((sa['profiles'] as List).single as Map)['arcaAddress'])});
    Map? colOf(Map<String, Object?> s) {
      final x = (s['following'] as List).cast<Map>().where((x) => x['pubkey'] == aPub);
      return x.isEmpty ? null : (x.single['collections'] as Map)[col] as Map?;
    }

    final sf = await waitFor(f, (s) => (colOf(s)?['files'] as List?)?.length == 600, what: 'F reads all 600 files');
    expect(colOf(sf)!['complete'], isTrue);
    await f.handle('sync', {'owner': aPub, 'collection': col});
    final done = await waitFor(f, (s) {
      final x = ((s['following'] as List).cast<Map>().single['synced'] as Map)[col] as Map?;
      return x != null && x['running'] == false && x['done'] == 600;
    }, what: 'F copied all 600');
    final folder = (((done['following'] as List).cast<Map>().single['synced'] as Map)[col] as Map)['folder'] as String;
    expect(File('$folder/file-599.txt').readAsStringSync(), 'content of file 599');
    for (final x in [a, f]) {
      await x.close();
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}
