// The chain over the live I2P network: three stewards, each with its own
// I2P node, pack a partition each, declare it, mine and post holding
// proofs for a few minute-long "days", then must agree on one chain.
//
//   dart run tool/live_chain_check.dart <data dir> <minutes> <file>...
import 'dart:async';
import 'dart:io';

import 'package:arca_core/arca_core.dart';
import 'package:arca_core/src/chain/corpus.dart';
import 'package:arca_core/src/chain/mining.dart';
import 'package:arca_core/src/chain/node.dart';
import 'package:arca_core/src/chain/params.dart';
import 'package:arca_core/src/chain/state.dart';
import 'package:arca_core/src/chain/tx.dart';

/// Testnet rules with partitions of 512 KB and one-minute days, so a few
/// small files make three partitions and a run shows several days.
const live = ChainParams(
  name: 'arca-live-check',
  partitionChunks: 2,
  tickMillis: 1000,
  dayTicks: 60,
  blockTicks: 5,
  packMemoryKiB: 32768,
  dailyIssuance: 100000 * ChainParams.grainsPerMarca,
  halvingDays: 30,
  floorIssuance: 1000 * ChainParams.grainsPerMarca,
  circleFee: 3000 * ChainParams.grainsPerMarca,
  fraudWindowTicks: 60,
);

final t0 = DateTime.now();
void say(String m) => print('${DateTime.now().difference(t0).inSeconds.toString().padLeft(4)}s  $m');

Future<void> main(List<String> args) async {
  final dir = args[0];
  final minutes = int.parse(args[1]);
  final paths = args.skip(2).toList();
  final files = <String, String>{};
  final chunked = <ChunkedFile>[];
  for (final p in paths) {
    final (sha, _, _) = await hashFile(File(p));
    files[sha] = p;
    chunked.add(await chunkFile(File(p), sha));
  }
  final corpus = Corpus.build(live, chunked);
  say(
    'corpus: ${corpus.chunks.length} chunks, ${corpus.partitions} partitions, root ${corpus.rootHex.substring(0, 16)}',
  );
  if (corpus.partitions < 3) exit(1);

  final cores = <CoreService>[];
  for (final n in ['a', 'b', 'c']) {
    cores.add(
      await CoreService.open(
        '$dir/$n',
        startNetwork: false,
        backend: I2pBackend('$dir/$n/i2p'),
        defaultBaseFolder: '$dir/$n/Arca',
      ),
    );
  }
  say('starting three I2P nodes');
  await Future.wait([for (final c in cores) c.net.start()]);
  // Bootstrapping I2P fails now and then (reseed servers, no peers yet);
  // a node gets three tries.
  for (final c in cores) {
    for (var attempt = 2; c.net.state != NetState.up && attempt <= 3; attempt++) {
      say('an I2P node did not start (${c.net.state.name}), try $attempt');
      await c.net.start();
    }
    if (c.net.state != NetState.up) {
      say('FAILED: an I2P node did not start (${c.net.state.name})');
      exit(1);
    }
  }
  final addresses = <String>[];
  final keys = <List<int>>[];
  for (final c in cores) {
    final s = await c.handle('state', {});
    final id = s['active'] as String;
    addresses.add(c.net.addressOf(id)!);
    keys.add(decodeEntity((await c.handle('exportNsec', {'id': id}))['nsec'] as String, 'nsec'));
  }
  say('network up: ${addresses.map((a) => a.substring(0, 8)).join(', ')}');
  final genesis = ChainState.genesis(
    live,
    circles: {'commons': CircleState(admin: toHex(publicKeyOf(keys[0])), name: 'Arca Commons')},
    collections: {
      for (var i = 0; i < corpus.partitions; i++)
        'part-$i': CollectionState(circle: 'commons', partitions: [i], seed: 100 * ChainParams.grainsPerMarca),
    },
    corpusRoot: corpus.rootHex,
    partitionSizes: [for (var i = 0; i < corpus.partitions; i++) corpus.chunksIn(i)],
    genesisTick: DateTime.now().millisecondsSinceEpoch ~/ live.tickMillis,
  );
  final nodes = <ChainNode>[];
  final logs = File('$dir/chain.log').openWrite();
  for (var i = 0; i < 3; i++) {
    final steward = Steward(
      params: live,
      key: toHex(publicKeyOf(keys[i])),
      corpus: corpus,
      folder: '$dir/packed-$i',
      files: files,
    );
    final sw = Stopwatch()..start();
    await steward.pack(i);
    say('steward ${'abc'[i]} packed partition $i in ${sw.elapsedMilliseconds} ms');
    nodes.add(
      ChainNode(
        params: live,
        genesis: genesis,
        address: addresses[i],
        link: cores[i].net.backend.link,
        secretKey: keys[i],
        steward: steward,
        peers: addresses,
      )..log = (m) => logs.writeln('${DateTime.now().difference(t0).inSeconds}s ${'abc'[i]}: $m'),
    );
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
  final end = DateTime.now().add(Duration(minutes: minutes));
  while (DateTime.now().isBefore(end)) {
    await Future<void>.delayed(const Duration(seconds: 30));
    say(
      [
        for (var i = 0; i < 3; i++)
          '${'abc'[i]}: h${nodes[i].state.height} d${nodes[i].state.day} ${nodes[i].headHash.isEmpty ? '-' : nodes[i].headHash.substring(0, 6)}',
      ].join('  '),
    );
  }
  for (final n in nodes) {
    n.mining = false;
  }
  say('mining stopped; letting the last blocks travel');
  await Future<void>.delayed(const Duration(seconds: 30));
  final s = nodes[0].state;
  final heads = {for (final n in nodes) n.headHash};
  final roots = {for (final n in nodes) n.state.rootHex};
  say(
    'height ${s.height}, day ${s.day}, pool ${(s.circles['commons']!.pool / ChainParams.grainsPerMarca).toStringAsFixed(0)} marcas, '
    'issued ${(s.issued / ChainParams.grainsPerMarca).toStringAsFixed(0)}',
  );
  for (var i = 0; i < 3; i++) {
    say(
      'steward ${'abc'[i]} declared: ${s.declarations[nodes[i].key] ?? 'dropped'}, '
      'last proof on day ${s.provenOn[nodes[i].key]?[i]}, standing ${(s.standing[nodes[i].key] ?? 0) / ChainParams.grainsPerMarca}',
    );
  }
  final pool = s.circles['commons']!.pool / live.issuanceOn(0);
  say('the pool holds ${pool.toStringAsFixed(4)} days of issuance');
  final ok =
      heads.length == 1 &&
      roots.length == 1 &&
      s.declarations.length == 3 &&
      s.day >= 2 &&
      (pool - pool.round()).abs() < 1e-6 &&
      pool.round() >= s.day - 2;
  say(ok ? 'ALL CHECKS PASSED: one chain on all three nodes' : 'FAILED: heads ${heads.length}, roots ${roots.length}');
  for (final n in nodes) {
    await n.stop();
  }
  for (final c in cores) {
    await c.close();
  }
  await logs.close();
  exit(ok ? 0 : 2);
}
