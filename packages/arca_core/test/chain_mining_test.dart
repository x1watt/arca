import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:arca_core/arca_core.dart';
import 'package:arca_core/src/chain/block.dart';
import 'package:arca_core/src/chain/corpus.dart';
import 'package:arca_core/src/chain/fraud.dart';
import 'package:arca_core/src/chain/mining.dart';
import 'package:arca_core/src/chain/params.dart';
import 'package:arca_core/src/chain/state.dart';
import 'package:arca_core/src/chain/tx.dart';
import 'package:test/test.dart';

/// Small and fast: 4 chunks per partition, 64 KiB of Argon2id, 100-tick days.
const p = ChainParams(
  name: 'test',
  partitionChunks: 4,
  tickMillis: 10,
  dayTicks: 100,
  blockTicks: 1,
  packMemoryKiB: 64,
  dailyIssuance: 1000 * ChainParams.grainsPerMarca,
  halvingDays: 10,
  floorIssuance: 10 * ChainParams.grainsPerMarca,
  circleFee: 0,
  fraudWindowTicks: 100,
);

void main() {
  late Directory tmp;
  late Corpus corpus;
  late Map<String, String> files;
  final keeperKey = generateSecretKey(), otherKey = generateSecretKey(), faucet = generateSecretKey();
  String pk(List<int> k) => toHex(publicKeyOf(k));

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('arca_mining');
    final rng = Random(5);
    files = {};
    final chunked = <ChunkedFile>[];
    for (var i = 0; i < 3; i++) {
      final f = File('${tmp.path}/f$i')
        ..writeAsBytesSync(Uint8List.fromList(List.generate(300 * 1024 + i * 7000, (_) => rng.nextInt(256))));
      final (sha, _, _) = await hashFile(f);
      files[sha] = f.path;
      chunked.add(await chunkFile(f, sha));
    }
    corpus = Corpus.build(p, chunked); // 6 chunks: two partitions
  });
  tearDown(() => tmp.delete(recursive: true));

  ChainState genesis() => ChainState.genesis(
    p,
    allocations: {pk(faucet): 100 * ChainParams.grainsPerMarca},
    circles: {'commons': CircleState(admin: pk(faucet), name: 'Arca Commons')},
    corpusRoot: corpus.rootHex,
    partitionSizes: [for (var i = 0; i < corpus.partitions; i++) corpus.chunksIn(i)],
  );

  Keeper keeper(List<int> key) => Keeper(
    params: p,
    key: pk(key),
    corpus: corpus,
    folder: '${tmp.path}/packed-${pk(key).substring(0, 6)}',
    files: files,
  );

  test('a packed slice proves up to the corpus, and only for its own keeper and challenge', () async {
    expect(corpus.partitions, 2);
    final s = keeper(keeperKey);
    await s.pack(0);
    final challenge = mineChallenge('', 1);
    final proof = await s.prove(challenge, 0, 'commons');
    final sizes = [corpus.chunksIn(0), corpus.chunksIn(1)];
    expect(await proof.check(p, challenge, corpus.rootHex, sizes), isNull);
    expect(await SliceProof.fromJson(proof.toJson()).check(p, mineChallenge('', 2), corpus.rootHex, sizes), isNotNull);
    // The same bytes claimed by another keeper do not unpack.
    final stolen = SliceProof.fromJson({...proof.toJson(), 'keeper': pk(otherKey)});
    expect(await stolen.check(p, challenge, corpus.rootHex, sizes), isNotNull);
  });

  /// A mined block by [key] at [tick] on [state], with [txs].
  Future<Block> mine(ChainState state, List<int> key, int tick, [List<Tx> txs = const []]) async {
    final part = state.declarations[pk(key)]!.keys.first;
    final proof = await keeper(key).prove(mineChallenge(state.head, tick), part, 'commons');
    return Block.produce(state, key, txs, tick: tick, proof: proof.toJson());
  }

  Future<ChainState> declared(List<int> key, int partition) async {
    final state = genesis();
    await keeper(key).pack(partition);
    final b = await Block.produce(state, faucet, [
      Tx.sign(key, TxType.declare, 0, {
        'circle': 'commons',
        'partitions': [partition],
      }),
    ], tick: 1);
    return b.applyTo(state);
  }

  test('a keeper mines; blocks create no marcas themselves; blocks without a fair proof are refused', () async {
    var state = await declared(keeperKey, 0);
    final block = await mine(state, keeperKey, 2);
    final next = await Block.fromJson(block.toJson()).applyTo(state);
    expect(next.height, state.height + 1);
    expect(next.issued, state.issued, reason: 'issuance is paid as each day closes (chain_rewards_test)');
    // Without a proof, or with someone else's proof, or above the target.
    await expectLater(Block.produce(state, faucet, const [], tick: 2), throwsA(isA<ChainError>()));
    await expectLater(
      Block.produce(state, otherKey, const [], tick: 2, proof: block.proof),
      throwsA(isA<ChainError>()),
    );
    state.target = BigInt.one;
    await expectLater(mine(state, keeperKey, 2), throwsA(predicate((e) => '$e'.contains('target'))));
  });

  test('a keeper that misses a day\'s holding proof loses its declarations; one that proves keeps them', () async {
    for (final prove in [true, false]) {
      var state = await declared(keeperKey, 0);
      // Day 1: the first block opens it; the keeper proves (or not).
      state = await (await mine(state, keeperKey, 100)).applyTo(state);
      expect(state.day, 1);
      if (prove) {
        final proof = await keeper(keeperKey).prove(holdChallenge(state.beacon, 1, pk(keeperKey), 0), 0, 'commons');
        final tx = Tx.sign(keeperKey, TxType.holdingProof, 0, {'day': 1, 'proof': proof.toJson()});
        final block = await mine(state, keeperKey, 101, [tx]);
        expect(block.txs, hasLength(1), reason: 'a valid holding proof is included');
        state = await block.applyTo(state);
      }
      // Day 2 opens: the check runs.
      state = await (await mine(state, keeperKey, 200)).applyTo(state);
      expect(state.declarations.containsKey(pk(keeperKey)), prove, reason: prove ? 'proved, kept' : 'missed, dropped');
    }
  });

  test('a holding proof for someone else\'s partition or the wrong slice is refused', () async {
    var state = await declared(keeperKey, 0);
    state = await (await mine(state, keeperKey, 100)).applyTo(state);
    final good = await keeper(keeperKey).prove(holdChallenge(state.beacon, 1, pk(keeperKey), 0), 0, 'commons');
    final wrongSlice = await keeper(keeperKey).prove(mineChallenge('x', 1), 0, 'commons');
    await expectLater(
      state.copy().apply(Tx.sign(keeperKey, TxType.holdingProof, 0, {'day': 1, 'proof': wrongSlice.toJson()})),
      throwsA(isA<ChainError>()),
    );
    await expectLater(
      state.copy().apply(Tx.sign(otherKey, TxType.holdingProof, 0, {'day': 1, 'proof': good.toJson()})),
      throwsA(isA<ChainError>()),
    );
    await state.copy().apply(Tx.sign(keeperKey, TxType.holdingProof, 0, {'day': 1, 'proof': good.toJson()}));
  });

  test('a block with a forged mining proof is refused, and a fraud proof shows it to light clients', () async {
    final state = genesis();
    await keeper(keeperKey).pack(0);
    final b1 = await Block.produce(state, faucet, [
      Tx.sign(keeperKey, TxType.declare, 0, {
        'circle': 'commons',
        'partitions': [0],
      }),
    ], tick: 1);
    final s1 = await b1.applyTo(state);
    final honest = await mine(s1, keeperKey, 2);
    // Bytes made up to look like a slice: the quality is cheap to fake,
    // only the memory-hard check catches it.
    final forged = {...honest.proof, 'packed': toHex(List.filled(ChainParams.sliceBytes, 7))};
    final bad = Block(
      height: honest.height,
      prev: honest.prev,
      tick: honest.tick,
      producer: honest.producer,
      txs: honest.txs,
      txRoot: honest.txRoot,
      stateRoot: honest.stateRoot,
      corpusRoot: honest.corpusRoot,
      proof: forged,
      sig: '',
      target: honest.target,
      traceRoot: honest.traceRoot,
      trace: honest.trace,
    ).signedBy(keeperKey);
    expect(bad.quality, lessThan(bad.target), reason: 'a light client alone would take it');
    await expectLater(bad.applyTo(s1), throwsA(predicate((e) => '$e'.contains('bad mining proof'))));
    final proof = (await FraudProof.build(s1, Header.of(b1), bad))!;
    expect(proof.json['step'], 0);
    await proof.verify(p, genesisRoot: state.rootHex);
  });
}
