// A phone as a light client: it follows headers from full nodes, reads its
// balance with a proof, drops a bad block once a full node shows the fraud,
// and can take a snapshot to become a full node.
import 'dart:math';

import 'package:arca_core/arca_core.dart';
import 'package:arca_core/src/chain/block.dart';
import 'package:arca_core/src/chain/fraud.dart';
import 'package:arca_core/src/chain/light.dart';
import 'package:arca_core/src/chain/node.dart';
import 'package:arca_core/src/chain/params.dart';
import 'package:arca_core/src/chain/rewards.dart' show recordProof;
import 'package:arca_core/src/chain/state.dart';
import 'package:arca_core/src/chain/tx.dart';
import 'package:arca_core/src/chain/wire.dart';
import 'package:test/test.dart';

const p = ChainParams(
  name: 'light-test',
  partitionChunks: 4,
  tickMillis: 20,
  dayTicks: 50,
  blockTicks: 2,
  packMemoryKiB: 64,
  dailyIssuance: 1000 * ChainParams.grainsPerMarca,
  halvingDays: 10,
  floorIssuance: 10 * ChainParams.grainsPerMarca,
  circleFee: 0,
  fraudWindowTicks: 25,
);
const m = ChainParams.grainsPerMarca;
String pk(List<int> k) => toHex(publicKeyOf(k));

Future<void> until(bool Function() ok, String what, {Duration limit = const Duration(seconds: 10)}) async {
  final end = DateTime.now().add(limit);
  while (!ok()) {
    if (DateTime.now().isAfter(end)) fail('timed out waiting for: $what');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  test('a light client follows full nodes, reads proven state, drops a block shown wrong, takes a snapshot', () async {
    final keyA = generateSecretKey(), keyB = generateSecretKey(), attacker = generateSecretKey();
    final genesis = ChainState.genesis(
      p,
      allocations: {pk(keyA): 1000 * m, pk(attacker): 1000 * m},
      circles: {'commons': CircleState(admin: pk(keyA), name: 'Commons')},
      genesisTick: DateTime.now().millisecondsSinceEpoch ~/ p.tickMillis,
    );
    final net = LoopbackNetwork();
    ChainNode full(String address, List<int> key) => ChainNode(
      params: p,
      genesis: genesis,
      address: address,
      link: net.link([address]),
      secretKey: key,
      peers: ['a', 'b'],
    );
    final a = full('a', keyA), b = full('b', keyB);
    final light = LightClient(
      params: p,
      genesisRoot: genesis.rootHex,
      genesisTick: genesis.genesisTick,
      address: 'phone',
      link: net.link(['phone']),
      peers: ['a', 'b'],
    );
    a.start();
    b.start();
    light.start();

    // Some burns make blocks.
    for (var i = 0; i < 5; i++) {
      a.submit(TxType.burn, {'amount': 10 * m});
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    await until(() => a.state.burned == 50 * m, 'the burns are in blocks');
    await until(() => light.headHash == a.headHash && light.headHash == b.headHash, 'the phone follows the head');
    expect(light.height, a.state.height);

    // The phone reads a balance, proven against its header.
    final read = await light.read('balances', [pk(keyA), pk(keyB)]);
    expect(read[pk(keyA)]!.value, '${950 * m}');
    expect(read[pk(keyB)]!.value, isNull, reason: 'absent, and proven absent');

    // An attacker makes a block that pays itself: the burn is real, the
    // result it signs is not.
    final parent = a.state;
    final honest = await Block.produce(parent, attacker, [
      Tx.sign(attacker, TxType.burn, 0, {'amount': 1 * m}),
    ], tick: a.currentTick + 1);
    final lie = parent.copy()..head = '';
    lie.balances[pk(attacker)] = 1000000 * m;
    final bad = Block(
      height: honest.height,
      prev: honest.prev,
      tick: honest.tick,
      producer: honest.producer,
      txs: honest.txs,
      txRoot: honest.txRoot,
      stateRoot: lie.rootHex,
      corpusRoot: honest.corpusRoot,
      proof: honest.proof,
      sig: '',
      target: honest.target,
      traceRoot: Block.traceRootOf([fromHex(honest.trace[0]), lie.root()]),
      trace: [honest.trace[0], lie.rootHex],
    ).signedBy(attacker);
    final attackerLink = net.link(['m']);
    // The phone hears of it first and, with nothing against it yet, takes it.
    await attackerLink.send('phone', encodeChainMessage({'t': 'header', 'h': Header.of(bad).toJson()}), from: 'm');
    await until(() => light.headHash == bad.hash, 'the phone takes the bad block');
    // A full node refuses it and shows why; the phone drops it.
    await attackerLink.send('a', encodeChainMessage({'t': 'block', 'b': bad.toJson()}), from: 'm');
    await until(() => light.rejected.contains(bad.hash), 'the phone drops the bad block');
    expect(light.headHash, isNot(bad.hash));
    expect(a.headHash, isNot(bad.hash));

    // A snapshot of the head rebuilds the full node's state.
    final at = a.headHash;
    await until(() => light.header(at) != null, 'the phone knows the head');
    final snap = await light.snapshot(at: at);
    expect(snap.balanceOf(pk(keyA)), a.state.balanceOf(pk(keyA)));
    expect(snap.height, a.state.height);

    // Past the fraud window, headers are final.
    await until(() => light.finalHash.isNotEmpty, 'a header becomes final', limit: const Duration(seconds: 5));

    await a.stop();
    await b.stop();
    await light.stop();
  }, timeout: const Timeout(Duration(minutes: 1)));

  test('a fraud proof for a day\'s settlement stays small however many keepers there are', () async {
    final rng = Random(7);
    Future<int> proofBytes(int keepers) async {
      final genesis = ChainState.genesis(
        p,
        circles: {'commons': CircleState(admin: 'a' * 64, name: 'C')},
        collections: {
          'files': CollectionState(circle: 'commons', partitions: [0], seed: 100 * m),
        },
        partitionSizes: [4],
      );
      for (var i = 0; i < keepers; i++) {
        final k = toHex(List.generate(32, (_) => rng.nextInt(256)));
        genesis.declarations[k] = {0: 'commons'};
        genesis.declaredOn[k] = {0: 0};
        genesis.keepers++;
        recordProof(genesis, k, 0, 'commons');
      }
      final producer = generateSecretKey();
      final honest = await Block.produce(genesis, producer, const [], tick: p.dayTicks + 1);
      final trace = [...honest.trace]..[1] = 'ab' * 32;
      final bad = Block(
        height: honest.height,
        prev: honest.prev,
        tick: honest.tick,
        producer: honest.producer,
        txs: const [],
        txRoot: honest.txRoot,
        stateRoot: trace.last,
        corpusRoot: honest.corpusRoot,
        proof: honest.proof,
        sig: '',
        target: honest.target,
        traceRoot: Block.traceRootOf([for (final r in trace) fromHex(r)]),
        trace: trace,
        settleSteps: honest.settleSteps,
      ).signedBy(producer);
      final proof = (await FraudProof.build(genesis, null, bad))!;
      expect(proof.json['step'], 1);
      // It travels (in parts if need be) and holds.
      final r = Reassembly();
      Map? whole;
      for (final part in Reassembly.split({'t': 'fraud', 'f': proof.json}).reversed) {
        whole = r.add(Inbound('x', 'y', encodeChainMessage(part))) ?? whole;
      }
      await FraudProof((whole!['f'] as Map).cast<String, Object?>()).verify(p, genesisRoot: genesis.rootHex);
      return canonicalJson(proof.json).length;
    }

    final small = await proofBytes(40), big = await proofBytes(400);
    print('settlement fraud proof: $small bytes with 40 keepers, $big bytes with 400');
    expect(big, lessThan(small * 2), reason: 'grows with the log of the keepers, not with their number');
  });
}
