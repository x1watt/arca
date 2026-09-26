// Fraud proofs: a full node shows a light client, holding only headers,
// that a block is wrong, with the few entries the wrong step touches.
import 'dart:convert';
import 'dart:math';

import 'package:arca_core/arca_core.dart';
import 'package:arca_core/src/chain/block.dart';
import 'package:arca_core/src/chain/fraud.dart';
import 'package:arca_core/src/chain/merkle.dart';
import 'package:arca_core/src/chain/params.dart';
import 'package:arca_core/src/chain/state.dart';
import 'package:arca_core/src/chain/tx.dart';
import 'package:test/test.dart';

const p = ChainParams.testnet;
const m = ChainParams.grainsPerMarca;
String pk(List<int> k) => toHex(publicKeyOf(k));
Matcher throwsFraud(String text) => throwsA(isA<FraudError>().having((e) => '$e', 'message', contains(text)));

void main() {
  final producer = generateSecretKey();
  final people = [for (var i = 0; i < 40; i++) generateSecretKey()];
  final rng = Random(5);
  String randomRoot() => toHex(List.generate(32, (_) => rng.nextInt(256)));

  late ChainState genesis;
  late String genesisRoot;
  setUp(() {
    genesis = ChainState.genesis(
      p,
      allocations: {for (final k in people) pk(k): 100 * m},
      circles: {'commons': CircleState(admin: pk(producer), name: 'Commons')},
    );
    genesisRoot = genesis.rootHex;
  });

  /// [b] with other trace entries and state root, signed again.
  Block rewrite(Block b, {List<String>? trace, String? stateRoot, List<Tx>? txs}) {
    final t = trace ?? b.trace;
    final x = txs ?? b.txs;
    return Block(
      height: b.height,
      prev: b.prev,
      tick: b.tick,
      producer: b.producer,
      txs: x,
      txRoot: Block.txsRoot(x),
      stateRoot: stateRoot ?? t.last,
      corpusRoot: b.corpusRoot,
      proof: b.proof,
      sig: '',
      target: b.target,
      traceRoot: Block.traceRootOf([for (final r in t) fromHex(r)]),
      trace: t,
    ).signedBy(producer);
  }

  /// Two honest blocks, so the bad one has a parent header.
  Future<(ChainState, Header)> history() async {
    final b1 = await Block.produce(genesis, producer, [
      Tx.sign(people[0], TxType.transfer, 0, {'to': pk(people[1]), 'amount': 5 * m}),
    ], tick: 1);
    final s1 = await b1.applyTo(genesis);
    return (s1, Header.of(b1));
  }

  test('an honest block has no fraud to show', () async {
    final (s1, h1) = await history();
    final b2 = await Block.produce(s1, producer, [
      Tx.sign(people[2], TxType.transfer, 0, {'to': pk(people[3]), 'amount': 7 * m}),
      Tx.sign(people[4], TxType.burn, 0, {'amount': 1 * m}),
    ], tick: 2);
    await b2.applyTo(s1);
    expect(await FraudProof.build(s1, h1, b2), isNull);
  });

  test('a transaction step with a wrong result is shown with a handful of entries', () async {
    final (s1, h1) = await history();
    final honest = await Block.produce(s1, producer, [
      Tx.sign(people[2], TxType.transfer, 0, {'to': pk(people[3]), 'amount': 7 * m}),
      Tx.sign(people[4], TxType.transfer, 0, {'to': pk(people[5]), 'amount': 1 * m}),
    ], tick: 2);
    // The producer claims another result for the first transaction.
    final bad = rewrite(honest, trace: [honest.trace[0], randomRoot(), honest.trace[2]]);
    await expectLater(bad.applyTo(s1), throwsA(isA<ChainError>()));
    final proof = (await FraudProof.build(s1, h1, bad))!;
    expect(proof.json['step'], 1);
    final witness = proof.json['witness'] as Map;
    expect(witness.keys.toSet(), {'meta', 'balances', 'nonces'});
    expect(((witness['balances'] as Map)['values'] as Map).keys.toSet(), {pk(people[2]), pk(people[3])});
    // It travels as JSON and checks with the headers alone.
    await FraudProof(jsonRoundTrip(proof.json)).verify(p, genesisRoot: genesisRoot);
    print('fraud proof for a transfer: ${canonicalJson(proof.json).length} bytes');
  });

  test('a block including a transaction that breaks a rule is shown', () async {
    final (s1, h1) = await history();
    final honest = await Block.produce(s1, producer, const [], tick: 2);
    final overspend = Tx.sign(people[6], TxType.transfer, 0, {'to': pk(people[7]), 'amount': 1000 * m});
    final bad = rewrite(honest, txs: [overspend], trace: [honest.trace[0], randomRoot()]);
    final proof = (await FraudProof.build(s1, h1, bad))!;
    expect(proof.json['step'], 1);
    await proof.verify(p, genesisRoot: genesisRoot);
  });

  test('a wrong day settlement is shown with the namespaces the settlement goes through', () async {
    final (s1, h1) = await history();
    // The next block opens day 1: the prelude settles day 0.
    final honest = await Block.produce(s1, producer, const [], tick: p.dayTicks + 1);
    final bad = rewrite(honest, trace: [randomRoot()]);
    final proof = (await FraudProof.build(s1, h1, bad))!;
    expect(proof.json['step'], 0);
    final witness = proof.json['witness'] as Map;
    expect((witness['declarations'] as Map).containsKey('full'), isTrue);
    await proof.verify(p, genesisRoot: genesisRoot);
  });

  test('a trace that does not end at the state root is shown', () async {
    final (s1, h1) = await history();
    final honest = await Block.produce(s1, producer, const [], tick: 2);
    final bad = rewrite(honest, stateRoot: randomRoot());
    final proof = (await FraudProof.build(s1, h1, bad))!;
    expect(proof.json['kind'], 'end');
    await proof.verify(p, genesisRoot: genesisRoot);
  });

  test('a proof against an honest block, an altered value or a missing entry does not hold', () async {
    final (s1, h1) = await history();
    final honest = await Block.produce(s1, producer, [
      Tx.sign(people[2], TxType.transfer, 0, {'to': pk(people[3]), 'amount': 7 * m}),
    ], tick: 2);
    final bad = rewrite(honest, trace: [honest.trace[0], randomRoot()]);
    final real = (await FraudProof.build(s1, h1, bad))!;

    // The same proof pointed at the honest block: the step is right.
    final leaves = [for (final r in honest.trace) leafHash(fromHex(r))];
    List<List<Object>> path(int i) => [
      for (final (h, right) in merkleProof(leaves, i)) [toHex(h), right],
    ];
    final againstHonest = jsonRoundTrip(real.json)
      ..['block'] = Header.of(honest).toJson()
      ..['prePath'] = path(0)
      ..['postLeaf'] = honest.trace[1]
      ..['postPath'] = path(1);
    await expectLater(FraudProof(againstHonest).verify(p, genesisRoot: genesisRoot), throwsFraud('the step is right'));

    // A witnessed balance changed.
    final altered = jsonRoundTrip(real.json);
    final values = ((altered['witness'] as Map)['balances'] as Map)['values'] as Map;
    values[pk(people[2])] = '${1000000 * m}';
    await expectLater(FraudProof(altered).verify(p, genesisRoot: genesisRoot), throwsFraud('not the proven one'));

    // The recipient's balance left out.
    final missing = jsonRoundTrip(real.json);
    final balances = (missing['witness'] as Map)['balances'] as Map;
    (balances['values'] as Map).remove(pk(people[3]));
    (balances['proofs'] as List).removeWhere((p) => (p as Map)['key'] == pk(people[3]));
    await expectLater(FraudProof(missing).verify(p, genesisRoot: genesisRoot), throwsFraud('does not carry'));

    // A header the producer did not sign.
    final unsigned = jsonRoundTrip(real.json);
    ((unsigned['block'] as Map)['fields'] as Map)['tick'] = 3;
    await expectLater(FraudProof(unsigned).verify(p, genesisRoot: genesisRoot), throwsFraud('not signed'));
  });
}

/// A deep copy as it would arrive over the network.
Map<String, Object?> jsonRoundTrip(Map<String, Object?> j) =>
    (jsonDecode(canonicalJson(j)) as Map).cast<String, Object?>();
