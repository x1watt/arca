import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:arca_core/arca_core.dart';
import 'package:arca_core/src/chain/block.dart';
import 'package:arca_core/src/chain/corpus.dart';
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
  final stewardKey = generateSecretKey(), otherKey = generateSecretKey(), faucet = generateSecretKey();
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

  Steward steward(List<int> key) => Steward(
    params: p,
    key: pk(key),
    corpus: corpus,
    folder: '${tmp.path}/packed-${pk(key).substring(0, 6)}',
    files: files,
  );

  test('a packed slice proves up to the corpus, and only for its own steward and challenge', () async {
    expect(corpus.partitions, 2);
    final s = steward(stewardKey);
    await s.pack(0);
    final challenge = mineChallenge('', 1);
    final proof = await s.prove(challenge, 0, 'commons');
    final sizes = [corpus.chunksIn(0), corpus.chunksIn(1)];
    expect(await proof.check(p, challenge, corpus.rootHex, sizes), isNull);
    expect(await SliceProof.fromJson(proof.toJson()).check(p, mineChallenge('', 2), corpus.rootHex, sizes), isNotNull);
    // The same bytes claimed by another steward do not unpack.
    final stolen = SliceProof.fromJson({...proof.toJson(), 'steward': pk(otherKey)});
    expect(await stolen.check(p, challenge, corpus.rootHex, sizes), isNotNull);
  });

  /// A mined block by [key] at [tick] on [state], with [txs].
  Future<Block> mine(ChainState state, List<int> key, int tick, [List<Tx> txs = const []]) async {
    final part = state.declarations[pk(key)]!.keys.first;
    final proof = await steward(key).prove(mineChallenge(state.head, tick), part, 'commons');
    return Block.produce(state, key, txs, tick: tick, proof: proof.toJson());
  }

  Future<ChainState> declared(List<int> key, int partition) async {
    final state = genesis();
    await steward(key).pack(partition);
    final b = await Block.produce(state, faucet, [
      Tx.sign(key, TxType.declare, 0, {
        'circle': 'commons',
        'partitions': [partition],
      }),
    ], tick: 1);
    return b.applyTo(state);
  }

  test('a steward mines; new marcas go to its circle pool; blocks without a fair proof are refused', () async {
    var state = await declared(stewardKey, 0);
    final pool = state.circles['commons']!.pool;
    final block = await mine(state, stewardKey, 2);
    final next = await Block.fromJson(block.toJson()).applyTo(state);
    final reward = p.issuanceOn(0) ~/ p.blocksPerDay;
    expect(next.circles['commons']!.pool, pool + reward);
    expect(next.issued, state.issued + reward);
    // Without a proof, or with someone else's proof, or above the target.
    await expectLater(Block.produce(state, faucet, const [], tick: 2), throwsA(isA<ChainError>()));
    await expectLater(
      Block.produce(state, otherKey, const [], tick: 2, proof: block.proof),
      throwsA(isA<ChainError>()),
    );
    state.target = BigInt.one;
    await expectLater(mine(state, stewardKey, 2), throwsA(predicate((e) => '$e'.contains('target'))));
  });

  test('a steward that misses a day\'s holding proof loses its declarations; one that proves keeps them', () async {
    for (final prove in [true, false]) {
      var state = await declared(stewardKey, 0);
      // Day 1: the first block opens it; the steward proves (or not).
      state = await (await mine(state, stewardKey, 100)).applyTo(state);
      expect(state.day, 1);
      if (prove) {
        final proof = await steward(stewardKey).prove(holdChallenge(state.beacon, 1, pk(stewardKey), 0), 0, 'commons');
        final tx = Tx.sign(stewardKey, TxType.holdingProof, 0, {'day': 1, 'proof': proof.toJson()});
        final block = await mine(state, stewardKey, 101, [tx]);
        expect(block.txs, hasLength(1), reason: 'a valid holding proof is included');
        state = await block.applyTo(state);
      }
      // Day 2 opens: the check runs.
      state = await (await mine(state, stewardKey, 200)).applyTo(state);
      expect(state.declarations.containsKey(pk(stewardKey)), prove, reason: prove ? 'proved, kept' : 'missed, dropped');
    }
  });

  test('a holding proof for someone else\'s partition or the wrong slice is refused', () async {
    var state = await declared(stewardKey, 0);
    state = await (await mine(state, stewardKey, 100)).applyTo(state);
    final good = await steward(stewardKey).prove(holdChallenge(state.beacon, 1, pk(stewardKey), 0), 0, 'commons');
    final wrongSlice = await steward(stewardKey).prove(mineChallenge('x', 1), 0, 'commons');
    await expectLater(
      state.copy().apply(Tx.sign(stewardKey, TxType.holdingProof, 0, {'day': 1, 'proof': wrongSlice.toJson()})),
      throwsA(isA<ChainError>()),
    );
    await expectLater(
      state.copy().apply(Tx.sign(otherKey, TxType.holdingProof, 0, {'day': 1, 'proof': good.toJson()})),
      throwsA(isA<ChainError>()),
    );
    await state.copy().apply(Tx.sign(stewardKey, TxType.holdingProof, 0, {'day': 1, 'proof': good.toJson()}));
  });
}
