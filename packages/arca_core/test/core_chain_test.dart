// The chain inside the core, as the app uses it: a founder starts a
// testnet from a collection, a second device joins with the invite, both
// keep and prove the corpus, pay each other, and the founder pays out the
// circle's pool, which the other claims. Then both restart from their
// snapshots.
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:arca_core/arca_core.dart';
import 'package:arca_core/src/chain/params.dart';
import 'package:test/test.dart';

const m = ChainParams.grainsPerMarca;

/// Fast rules: days of six seconds.
const fast = ChainParams(
  name: 'arca-core-test',
  partitionChunks: 4,
  tickMillis: 100,
  dayTicks: 60,
  blockTicks: 3,
  packMemoryKiB: 256,
  dailyIssuance: 1000 * ChainParams.grainsPerMarca,
  halvingDays: 10,
  floorIssuance: 10 * ChainParams.grainsPerMarca,
  circleFee: 0,
  fraudWindowTicks: 60,
);

Future<Map<String, Object?>> waitFor(
  CoreService c,
  bool Function(Map<String, Object?> s) ok, {
  String what = '',
  int seconds = 60,
}) async {
  Map<String, Object?> s = {};
  final end = DateTime.now().add(Duration(seconds: seconds));
  while (DateTime.now().isBefore(end)) {
    s = await c.handle('state', {});
    if (ok(s)) return s;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  throw StateError('condition not reached: $what; chain: ${s['chain']}');
}

Map chainOf(Map<String, Object?> s) => (s['chain'] as Map?) ?? const {};
bool ready(Map<String, Object?> s) {
  final c = chainOf(s);
  final parts = (c['partitions'] as List?)?.cast<Map>() ?? const [];
  return (c['corpus'] as Map?)?['ready'] == true && parts.isNotEmpty && parts.every((p) => p['declared'] == true);
}

void main() {
  late Directory tmp;
  setUp(() async => tmp = await Directory.systemTemp.createTemp('arca_core_chain'));
  tearDown(() async => tmp.delete(recursive: true));

  test('start a testnet, join by invite, keep the corpus, pay, pay out and claim, restart', () async {
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

    var a = await open('founder'), b = await open('joiner');
    Future<Map> me(CoreService c) async => ((await c.handle('state', {}))['profiles'] as List).single as Map;

    // The founder's collection: five chunks, so two partitions.
    final rng = Random(3);
    final paths = [
      for (final (name, size) in [('talk.bin', 700 * 1024), ('notes.bin', 500 * 1024)])
        (File(
          '${tmp.path}/$name',
        )..writeAsBytesSync(Uint8List.fromList(List.generate(size, (_) => rng.nextInt(256))))).path,
    ];
    final col = (await a.handle('createCollection', {'name': 'Library'}))['created'] as String;
    await a.handle('addFiles', {'collection': col, 'paths': paths});

    var r = await a.handle('chainStart', {'collection': col, 'params': fast.toJson()});
    expect(r['error'], isNull);
    var sa = await waitFor(a, ready, what: 'the founder packs and declares');
    expect((chainOf(sa)['partitions'] as List), hasLength(2));
    expect(chainOf(sa)['balance'], 10000 * m, reason: 'the founder\'s test allocation');
    final invite = chainOf(sa)['invite'] as String;

    // The second device joins: it copies the collection, rebuilds the corpus
    // and checks its root, then packs and declares.
    r = await b.handle('chainJoin', {'invite': invite});
    expect(r['error'], isNull, reason: '${r['error']}');
    var sb = await waitFor(b, ready, what: 'the joiner copies, packs and declares', seconds: 90);
    expect(chainOf(sb)['founder'], isFalse);

    // A payment.
    r = await a.handle('chainSend', {'to': (await me(b))['npub'], 'amount': '25'});
    expect(r['error'], isNull);
    sb = await waitFor(b, (s) => chainOf(s)['balance'] == 25 * m, what: 'the payment arrives');
    r = await a.handle('chainSend', {'to': 'nobody', 'amount': '1'});
    expect(r['error'], contains('npub'));
    r = await b.handle('chainSend', {'to': (await me(a))['npub'], 'amount': '1000'});
    expect(r['error'], contains('not enough'));

    // Days pass; both prove their keeping; the pool fills.
    sa = await waitFor(
      a,
      (s) => ((chainOf(s)['circle'] as Map?)?['pool'] as int? ?? 0) > 0 && chainOf(s)['syncScore'] as int > 0,
      what: 'the pool earns',
      seconds: 60,
    );
    await waitFor(b, (s) => chainOf(s)['syncScore'] as int > 0, what: 'the joiner has proven its keeping', seconds: 60);
    final heightBefore = chainOf(sa)['height'] as int;

    // The founder pays out; once anchored, the joiner claims its share.
    r = await a.handle('chainPayout', {});
    expect(r['error'], isNull);
    final balanceBefore = chainOf(sb)['balance'] as int;
    Map<String, Object?>? claim;
    final end = DateTime.now().add(const Duration(seconds: 60));
    while (DateTime.now().isBefore(end)) {
      claim = await b.handle('chainClaim', {});
      if (claim['error'] == null) break;
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    expect(claim!['error'], isNull, reason: 'the claim went through: ${claim['error']}');
    sb = await waitFor(b, (s) => (chainOf(s)['balance'] as int) > balanceBefore, what: 'the claim is paid');
    print('joiner: ${(chainOf(sb)['balance'] as int) / m} marcas after the claim');

    // The admin sets how the circle is read; once anchored, the joiner
    // buys a pass.
    r = await a.handle('chainReading', {'passPrice': '2', 'freeAllowance': 50 * 1024 * 1024, 'memberScore': 0});
    expect(r['error'], isNull);
    sb = await waitFor(
      b,
      (s) => (chainOf(s)['reading'] as Map?)?['passPrice'] == 2 * m,
      what: 'the reading settings are anchored',
    );
    final beforePass = chainOf(sb)['balance'] as int;
    r = await b.handle('chainBuyPass', {});
    expect(r['error'], isNull, reason: '${r['error']}');
    sb = await waitFor(b, (s) => (chainOf(s)['reading'] as Map?)?['myPass'] != null, what: 'the pass is on the chain');
    expect(chainOf(sb)['balance'], beforePass - 2 * m);

    // A phone follows lightly: headers and proven reads, nothing kept.
    final c = await open('phone');
    r = await c.handle('chainJoin', {'invite': invite, 'light': true});
    expect(r['error'], isNull, reason: '${r['error']}');
    var sc = await waitFor(
      c,
      (s) => chainOf(s)['light'] == true && (chainOf(s)['height'] as int) > 0,
      what: 'the phone follows',
    );
    r = await a.handle('chainSend', {'to': (await me(c))['npub'], 'amount': '3'});
    expect(r['error'], isNull);
    sc = await waitFor(c, (s) => chainOf(s)['balance'] == 3 * m, what: 'the phone reads its balance with a proof');
    r = await c.handle('chainSend', {'to': (await me(a))['npub'], 'amount': '1'});
    expect(r['error'], isNull, reason: 'a light device sends too');
    await waitFor(
      c,
      (s) => chainOf(s)['balance'] == 2 * m && chainOf(s)['pending'] == 0,
      what: 'the phone\'s payment went in',
    );
    expect((chainOf(sc)['partitions'] as List), isEmpty);
    await c.close();

    // Both restart from their snapshots and carry on.
    await Future<void>.delayed(const Duration(seconds: 31)); // a snapshot is saved every 30 s
    await a.close();
    await b.close();
    a = await open('founder');
    b = await open('joiner');
    sa = await waitFor(a, (s) => (chainOf(s)['height'] as int? ?? 0) > heightBefore, what: 'the founder resumes');
    sb = await waitFor(b, ready, what: 'the joiner resumes', seconds: 60);

    // Newcomers after the founder restarted: its node keeps no blocks older
    // than its snapshot, so they start from its checkpoint.
    final late = await open('late'), lateLight = await open('late-phone');
    r = await late.handle('chainJoin', {'invite': invite});
    expect(r['error'], isNull, reason: '${r['error']}');
    r = await lateLight.handle('chainJoin', {'invite': invite, 'light': true});
    expect(r['error'], isNull, reason: '${r['error']}');
    await waitFor(late, ready, what: 'a late full node joins from the checkpoint', seconds: 90);
    final heightNow = chainOf(await a.handle('state', {}))['height'] as int;
    await waitFor(
      lateLight,
      (s) => (chainOf(s)['height'] as int? ?? 0) >= heightNow && chainOf(s)['balance'] == 0,
      what: 'a late phone follows from the checkpoint',
    );
    for (final c in [late, lateLight, a, b]) {
      await c.close();
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}
