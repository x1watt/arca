// A forger at the meeting point (docs/architecture.md, 10). Anyone can
// answer there, so a newcomer may meet a node that shows a chain claiming
// far more work than the honest one, with every mining proof invented. The
// newcomer checks the chains it is shown (chain/verify.dart), refuses the
// forged one and joins the honest founder's.
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:arca_core/arca_core.dart';
import 'package:arca_core/src/chain/block.dart';
import 'package:arca_core/src/chain/fraud.dart';
import 'package:arca_core/src/chain/mining.dart';
import 'package:arca_core/src/chain/params.dart';
import 'package:arca_core/src/chain/testnet.dart';
import 'package:arca_core/src/chain/wire.dart';
import 'package:i2p/i2p.dart' show sharedDestinationAddress;
import 'package:test/test.dart';

const fast = ChainParams(
  name: 'arca-meeting-test',
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

Map chainOf(Map<String, Object?> s) => (s['chain'] as Map?) ?? const {};

Future<Map<String, Object?>> waitFor(CoreService c, bool Function(Map<String, Object?> s) ok, String what) async {
  Map<String, Object?> s = {};
  final end = DateTime.now().add(const Duration(seconds: 120));
  while (DateTime.now().isBefore(end)) {
    s = await c.handle('state', {});
    if (ok(s)) return s;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  throw StateError('condition not reached: $what; chain: ${s['chain']}, error: ${s['chainError']}');
}

/// A node that answers at the meeting point with a chain of its own: the
/// spec's genesis, then blocks whose proofs are made up, each claiming 64
/// times the honest work.
class Forger {
  Forger(this.net, this.spec, this.rendezvous) : address = 'forger${Random().nextInt(1 << 30)}.b32.i2p';

  final LoopbackNetwork net;
  final TestnetSpec spec;
  final String rendezvous;
  final String address;
  final key = generateSecretKey();
  final chain = <Header>[];
  final _parts = Reassembly();
  late final MessageLink _link;

  void start() {
    final target = maxTarget >> 6;
    final rng = Random(7);
    var prev = '';
    final now = DateTime.now().millisecondsSinceEpoch ~/ fast.tickMillis;
    for (var tick = spec.genesisTick + 1; tick < now && chain.length < 40; tick++) {
      Map<String, Object?> proof;
      while (true) {
        final packed = Uint8List.fromList(List.generate(64, (_) => rng.nextInt(256)));
        proof = {
          'keeper': toHex(publicKeyOf(key)),
          'circle': spec.circleId,
          'partition': 0,
          'chunk': 0,
          'chunkLength': 1024,
          'slice': 0,
          'packed': toHex(packed),
          'slicePath': const [],
          'chunkPath': const [],
          'partitionPath': const [],
        };
        if (proofQuality(mineChallenge(prev, tick), toHex(publicKeyOf(key)), packed) < target) break;
      }
      final fields = <String, Object?>{
        'height': chain.length + 1,
        'prev': prev,
        'tick': tick,
        'producer': toHex(publicKeyOf(key)),
        'target': target.toRadixString(16),
        'txRoot': '00' * 32,
        'txCount': 0,
        'settleSteps': 0,
        'stateRoot': '11' * 32,
        'traceRoot': '22' * 32,
        'corpusRoot': spec.corpusRoot,
        'proof': proof,
      };
      final h = Header(fields, toHex(schnorrSign(key, fromHex(Block.hashOf(fields)))));
      chain.add(h);
      prev = h.hash;
    }
    _link = net.link([address, rendezvous]);
    _link.incoming.listen((m) {
      final msg = _parts.add(m);
      if (msg == null) return;
      Map<String, Object?>? reply;
      switch (msg['t']) {
        case 'hello':
          reply = {
            't': 'peers',
            'peers': [address],
          };
        case 'getHeaders':
          final from = msg['from'] as int;
          reply = {
            't': 'headers',
            'headers': [for (final h in chain.skip(from - 1).take(msg['n'] as int)) h.summary.toJson()],
          };
        case 'getProof':
          reply = {
            't': 'proof',
            'header': chain.where((h) => h.hash == msg['hash']).firstOrNull?.toJson(),
          };
      }
      if (reply == null) return;
      for (final part in Reassembly.split({...reply, 'id': msg['id']})) {
        _link.send(m.from, encodeChainMessage(part), from: m.to == rendezvous ? address : m.to);
      }
    });
  }
}

void main() {
  late Directory tmp;
  setUp(() async => tmp = await Directory.systemTemp.createTemp('arca_meeting'));
  tearDown(() async => tmp.delete(recursive: true));

  test('a forger at the meeting point claims more work, and the newcomer joins the honest chain', () async {
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

    final a = await open('founder');
    final rng = Random(3);
    final path = (File('${tmp.path}/talk.bin')
      ..writeAsBytesSync(Uint8List.fromList(List.generate(700 * 1024, (_) => rng.nextInt(256))))).path;
    final col = (await a.handle('createCollection', {'name': 'Library'}))['created'] as String;
    await a.handle('addFiles', {
      'collection': col,
      'paths': [path],
    });
    expect((await a.handle('chainStart', {'collection': col, 'params': fast.toJson()}))['error'], isNull);
    final spec = TestnetSpec(((await a.handle('chainSpec', {}))['spec'] as Map).cast<String, Object?>());
    await waitFor(a, (s) => (chainOf(s)['height'] as int? ?? 0) >= 3, 'the founder makes blocks');

    final (enc, sign) = spec.rendezvousSeeds;
    final forger = Forger(net, spec, await sharedDestinationAddress(enc, sign))..start();
    var claimed = BigInt.zero;
    for (final h in forger.chain) {
      claimed += h.work;
    }
    final honest = chainOf(await a.handle('state', {}))['height'] as int;
    expect(claimed, greaterThan(BigInt.from(honest * 4)), reason: 'the forgery claims far more work');

    final b = await open('newcomer');
    final r = await b.handle('chainJoin', {'spec': spec.json});
    expect(r['error'], isNull, reason: '${r['error']}');
    final sb = await waitFor(b, (s) => (chainOf(s)['height'] as int? ?? 0) >= honest, 'the newcomer follows');
    // On the founder's chain: it sees the founder's allocation spent on
    // nothing, and it can be paid by the founder.
    expect((await a.handle('chainSend', {'to': ((sb['profiles'] as List).single as Map)['npub'], 'amount': '3'}))['error'], isNull);
    await waitFor(b, (s) => chainOf(s)['balance'] == 3 * ChainParams.grainsPerMarca, 'the founder\'s payment arrives');
    await a.close();
    await b.close();
  }, timeout: const Timeout(Duration(minutes: 4)));
}
