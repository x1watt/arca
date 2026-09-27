// A newcomer checks a peer's chain before trusting it (chain/verify.dart):
// header summaries from a trusted anchor, and the mining proofs of a sample
// drawn by work, with the memory-hard part. A chain that claims more work
// than the honest one but invents it fails; the honest one holds.
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
import 'package:arca_core/src/chain/verify.dart';
import 'package:test/test.dart';

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
  final keeperKey = generateSecretKey(), attacker = generateSecretKey(), faucet = generateSecretKey();
  String pk(List<int> k) => toHex(publicKeyOf(k));

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('arca_verify');
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
    corpus = Corpus.build(p, chunked);
  });
  tearDown(() => tmp.delete(recursive: true));

  List<int> sizes() => [for (var i = 0; i < corpus.partitions; i++) corpus.chunksIn(i)];

  ChainChecker checker({int recent = 2, int samples = 8}) => ChainChecker(
    params: p,
    corpusRoot: corpus.rootHex,
    partitionSizes: sizes(),
    recent: recent,
    samples: samples,
    random: Random(1),
    currentTick: () => 100000,
  );

  /// An honest chain: a declaration, then blocks mined with real proofs.
  Future<List<Header>> honest(int blocks, {int first = 1}) async {
    var state = ChainState.genesis(
      p,
      allocations: {pk(faucet): 100 * ChainParams.grainsPerMarca},
      circles: {'commons': CircleState(admin: pk(faucet), name: 'Arca Commons')},
      corpusRoot: corpus.rootHex,
      partitionSizes: sizes(),
    );
    final keeper = Keeper(params: p, key: pk(keeperKey), corpus: corpus, folder: '${tmp.path}/packed', files: files);
    await keeper.pack(0);
    final headers = <Header>[];
    var b = await Block.produce(state, faucet, [
      Tx.sign(keeperKey, TxType.declare, 0, {
        'circle': 'commons',
        'partitions': [0],
      }),
    ], tick: first);
    state = await b.applyTo(state);
    headers.add(Header.of(b));
    for (var tick = first + 1; headers.length <= blocks; tick++) {
      final proof = await keeper.prove(mineChallenge(state.head, tick), 0, 'commons');
      if (proofQuality(mineChallenge(state.head, tick), pk(keeperKey), proof.packed) >= state.target) continue;
      b = await Block.produce(state, keeperKey, const [], tick: tick, proof: proof.toJson());
      state = await b.applyTo(state);
      headers.add(Header.of(b));
    }
    return headers;
  }

  /// A signed header with an invented proof: random "packed" bytes, ground
  /// until they meet a hard target, so it claims much more work.
  Header forged(List<int> key, String prev, int height, int tick, Header like, BigInt target) {
    final rng = Random(height);
    final real = SliceProof.fromJson(like.proof);
    Map<String, Object?> proof;
    while (true) {
      final packed = Uint8List.fromList(List.generate(real.packed.length, (_) => rng.nextInt(256)));
      proof = {...real.toJson(), 'keeper': pk(key), 'packed': toHex(packed)};
      if (proofQuality(mineChallenge(prev, tick), pk(key), packed) < target) break;
    }
    final fields = {...like.fields, 'height': height, 'prev': prev, 'tick': tick, 'producer': pk(key), 'target': target.toRadixString(16), 'proof': proof};
    return Header(fields, toHex(schnorrSign(key, fromHex(Block.hashOf(fields)))));
  }

  Future<Header?> Function(Header) fromList(List<Header> full) =>
      (s) async => full.where((h) => h.hash == s.hash).firstOrNull;

  test('an honest chain holds, from summaries and the sampled proofs', () async {
    final chain = await honest(12);
    final summaries = [for (final h in chain) h.summary];
    expect(summaries.every((s) => s.isSummary && s.signed), isTrue, reason: 'a summary is signed like its header');
    final r = await checker().check(Anchor.genesis(0), summaries, fromList(chain));
    expect(r.error, isNull);
    expect(r.work, BigInt.from(chain.length), reason: 'at the largest target each block is worth one');
    expect(r.tip!.hash, chain.last.hash);
  });

  test('a chain that invents its work fails, however much it claims', () async {
    final chain = await honest(4);
    final hard = maxTarget >> 5; // each forged block claims 32 times the work
    final fake = <Header>[chain.first];
    for (var i = 0; i < 20; i++) {
      fake.add(forged(attacker, fake.last.hash, fake.length + 1, fake.last.tick + 1, chain[1], hard));
    }
    final summaries = [for (final h in fake) h.summary];
    final r = await checker().check(Anchor.genesis(0), summaries, fromList(fake));
    expect(r.ok, isFalse);
    expect(r.error, contains('block'));
    // Honest work is small here, and the forgery claims far more: only the
    // proof check tells them apart.
    var claimed = BigInt.zero;
    for (final h in fake) {
      claimed += h.work;
    }
    expect(claimed, greaterThan(BigInt.from(chain.length)));
  });

  test('a forged stretch hidden among real blocks is found by sampling by work', () async {
    final chain = await honest(10);
    final hard = maxTarget >> 6;
    // Real blocks, then forged ones carrying nearly all the claimed work,
    // then one more real-looking tail that the "recent" check passes over.
    final fake = <Header>[...chain.take(6)];
    for (var i = 0; i < 5; i++) {
      fake.add(forged(attacker, fake.last.hash, fake.length + 1, fake.last.tick + 1, chain[1], hard));
    }
    final r = await checker(recent: 0, samples: 6).check(Anchor.genesis(0), [for (final h in fake) h.summary], fromList(fake));
    expect(r.ok, isFalse);
  });

  test('a summary that was changed, or a proof that is not its own, is refused', () async {
    final chain = await honest(5);
    final summaries = [for (final h in chain) h.summary];
    final changed = Header({...summaries[3].fields, 'stateRoot': '00' * 32}, summaries[3].sig);
    var r = await checker().check(Anchor.genesis(0), [...summaries.take(3), changed, ...summaries.skip(4)], fromList(chain));
    expect(r.error, contains('signed'));
    // A peer answers a sampled height with another block's proof.
    r = await checker(recent: 5).check(Anchor.genesis(0), summaries, (s) async => chain[2]);
    expect(r.error, contains('not its own'));
    // A gap, or an anchor it does not follow.
    r = await checker().check(Anchor.genesis(0), summaries.skip(1).toList(), fromList(chain));
    expect(r.error, contains('does not follow'));
  });

  test('from a checkpoint built into a release: its chain holds, one without it does not', () async {
    final chain = await honest(8);
    final cp = chain[3];
    var work = BigInt.zero;
    for (final h in chain.take(4)) {
      work += h.work;
    }
    final anchor = Anchor(hash: cp.hash, height: cp.height, tick: cp.tick, work: work);
    final after = [for (final h in chain.skip(4)) h.summary];
    var r = await checker().check(anchor, after, fromList(chain));
    expect(r.error, isNull);
    expect(r.work, BigInt.from(chain.length));
    // Another chain at the same heights, not built on the checkpoint.
    final other = await honest(8, first: 2);
    r = await checker().check(anchor, [for (final h in other.skip(4)) h.summary], fromList(other));
    expect(r.error, contains('another parent'));
  });
}
