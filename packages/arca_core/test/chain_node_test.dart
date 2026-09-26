// A testnet in one process: keepers pack their partitions, declare them,
// mine blocks, post daily holding proofs and gossip everything over the
// loopback network; one of them declares a partition it does not keep.
// Run once on a perfect network and once losing 30% of all messages, as
// best-effort I2P delivery does, which forks the chain and loses
// transactions until the nodes resync.
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:arca_core/arca_core.dart';
import 'package:arca_core/src/chain/circle_log.dart';
import 'package:arca_core/src/chain/corpus.dart';
import 'package:arca_core/src/chain/mining.dart';
import 'package:arca_core/src/chain/node.dart';
import 'package:arca_core/src/chain/params.dart';
import 'package:arca_core/src/chain/state.dart';
import 'package:arca_core/src/chain/tx.dart';
import 'package:test/test.dart';

/// Days of 50 ticks: about five of them per run.
ChainParams params(int tickMillis) => ChainParams(
  name: 'test',
  partitionChunks: 4,
  tickMillis: tickMillis,
  dayTicks: 50,
  blockTicks: 2,
  packMemoryKiB: 64,
  dailyIssuance: 1000 * ChainParams.grainsPerMarca,
  halvingDays: 10,
  floorIssuance: 10 * ChainParams.grainsPerMarca,
  circleFee: 0,
  fraudWindowTicks: 50,
);

void main() {
  // With late messages, ticks are longer (the same five days take twice
  // as long), so a busy machine still fits a holding proof into each day.
  for (final (drop, latency, tick) in [(0.0, 0, 20), (0.3, 0, 20), (0.3, 60, 40)]) {
    test(
      'keepers mine, prove their keeping every day, agree on one chain; a false claim is dropped '
      '(${(drop * 100).round()}% of messages lost, up to $latency ms late)',
      () => run(drop, Duration(milliseconds: latency), params(tick)),
      timeout: const Timeout(Duration(minutes: 2)),
    );
  }
}

Future<void> run(double drop, Duration latency, ChainParams p) async {
  final tmp = await Directory.systemTemp.createTemp('arca_chain');
  final rng = Random(9);
  final files = <String, String>{};
  final chunked = <ChunkedFile>[];
  for (var i = 0; i < 4; i++) {
    final f = File('${tmp.path}/f$i')
      ..writeAsBytesSync(Uint8List.fromList(List.generate(700 * 1024, (_) => rng.nextInt(256))));
    final (sha, _, _) = await hashFile(f);
    files[sha] = f.path;
    chunked.add(await chunkFile(f, sha));
  }
  final corpus = Corpus.build(p, chunked);
  expect(corpus.partitions, greaterThanOrEqualTo(3));
  final faucet = generateSecretKey();
  final names = ['a', 'b', 'c', 'liar'];
  final keys = [for (final _ in names) generateSecretKey()];
  // Keeper a administers the commons: its circle log lists one collection
  // per partition, and its node anchors the log so the circle keeps earning.
  final log = CircleLog('commons', admin: toHex(publicKeyOf(keys[0])));
  log.write(keys[0], LogType.appoint, {'key': toHex(publicKeyOf(keys[0]))});
  for (var i = 0; i < corpus.partitions; i++) {
    log.write(keys[0], LogType.collection, {
      'id': 'part-$i',
      'partitions': [i],
    });
  }
  final genesis = ChainState.genesis(
    p,
    allocations: {toHex(publicKeyOf(faucet)): 1000 * ChainParams.grainsPerMarca},
    circles: {'commons': CircleState(admin: toHex(publicKeyOf(keys[0])), name: 'Arca Commons')},
    // One seeded collection per partition, so the interest budget pays too.
    collections: {
      for (var i = 0; i < corpus.partitions; i++)
        'part-$i': CollectionState(circle: 'commons', partitions: [i], seed: 100 * ChainParams.grainsPerMarca),
    },
    corpusRoot: corpus.rootHex,
    partitionSizes: [for (var i = 0; i < corpus.partitions; i++) corpus.chunksIn(i)],
    genesisTick: DateTime.now().millisecondsSinceEpoch ~/ p.tickMillis,
  );
  final net = LoopbackNetwork(dropRate: drop, latency: latency, seed: 3);
  final nodes = <ChainNode>[];
  for (final n in names) {
    final key = keys[names.indexOf(n)];
    final keeper = Keeper(
      params: p,
      key: toHex(publicKeyOf(key)),
      corpus: corpus,
      folder: '${tmp.path}/$n',
      files: files,
    );
    nodes.add(
      ChainNode(
          params: p,
          genesis: genesis,
          address: n,
          link: net.link([n]),
          secretKey: key,
          keeper: keeper,
          peers: names,
        )
        ..log = (Platform.environment['ARCA_CHAIN_LOG'] == null ? null : (m) => print('$n: $m'))
        ..anchorBody = (n == 'a' ? (_) => log.anchorBody() : null),
    );
  }
  // The honest keepers pack a partition each; the liar packs nothing.
  for (var i = 0; i < 3; i++) {
    await nodes[i].keeper!.pack(i);
  }
  for (final n in nodes) {
    n.start();
  }
  for (var i = 0; i < 3; i++) {
    nodes[i].submit(TxType.declare, {
      'circle': 'commons',
      'partitions': [i],
    });
  }
  nodes[3].submit(TxType.declare, {
    'circle': 'commons',
    'partitions': [0],
  });

  // About four "days".
  await Future<void>.delayed(Duration(milliseconds: 250 * p.tickMillis));
  // Stop mining but keep listening, so the last blocks reach everyone.
  for (final n in nodes) {
    n.mining = false;
  }
  net
    ..dropRate = 0
    ..latency = Duration.zero;
  await Future<void>.delayed(const Duration(seconds: 1));
  for (final n in nodes) {
    await n.stop();
  }
  // Everyone ends on the same chain.
  final heads = {for (final n in nodes) n.headHash};
  final s = nodes[0].state;
  print(
    'height ${s.height}, day ${s.day}, pool ${s.circles['commons']!.pool / ChainParams.grainsPerMarca} marcas, '
    'heads ${heads.length}, declared ${s.declarations.length}',
  );
  expect(heads, hasLength(1), reason: 'one chain');
  expect(s.day, greaterThanOrEqualTo(3));
  // Every day the keepers proved paid its whole issuance, storage and
  // interest, to their circle. Proofs start the day after the declarations
  // land: day 1, or day 2 on a busy machine. With one-second test days a
  // loaded machine can also miss one day's anchor or proofs, which pays
  // nothing that day; real days are ten minutes or a day long.
  final days = s.circles['commons']!.pool / p.issuanceOn(0);
  expect((days - days.round()).abs(), lessThan(1e-6), reason: 'whole days of issuance, $days');
  expect(days.round(), inInclusiveRange(s.day - 3, s.day - 1));
  expect(s.circles['commons']!.logHead, log.head, reason: 'the circle\'s log is anchored');
  expect(s.day - s.dayOf(s.circles['commons']!.anchoredAt), lessThanOrEqualTo(1));
  for (var i = 0; i < 3; i++) {
    expect(s.declarations[nodes[i].key], {i: 'commons'}, reason: 'keeper $i proved its keeping every day');
  }
  expect(s.declarations.containsKey(nodes[3].key), isFalse, reason: 'the false claim was dropped');
  await tmp.delete(recursive: true);
}
