// The chain over the live I2P network: three keepers, each with its own
// I2P node, pack a partition each, declare it, mine and post holding
// proofs for a few minute-long "days", then must agree on one chain.
//
//   dart run tool/live_chain_check.dart <data dir> <minutes> <file>...
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:arca_core/arca_core.dart';
import 'package:arca_core/src/chain/block.dart';
import 'package:arca_core/src/chain/circle_log.dart';
import 'package:arca_core/src/chain/corpus.dart';
import 'package:arca_core/src/chain/fraud.dart';
import 'package:arca_core/src/chain/light.dart';
import 'package:arca_core/src/chain/mining.dart';
import 'package:arca_core/src/chain/node.dart';
import 'package:arca_core/src/chain/params.dart';
import 'package:arca_core/src/chain/state.dart';
import 'package:arca_core/src/chain/tx.dart';
import 'package:arca_core/src/chain/wire.dart';

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
  // Keeper a administers the commons: its log lists one public
  // collection per partition, and its node anchors it about hourly.
  final log = CircleLog('commons', admin: toHex(publicKeyOf(keys[0])));
  log.write(keys[0], LogType.appoint, {'key': toHex(publicKeyOf(keys[0]))});
  for (var i = 0; i < corpus.partitions; i++) {
    log.write(keys[0], LogType.collection, {
      'id': 'part-$i',
      'partitions': [i],
    });
  }
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
    final keeper = Keeper(
      params: live,
      key: toHex(publicKeyOf(keys[i])),
      corpus: corpus,
      folder: '$dir/packed-$i',
      files: files,
    );
    final sw = Stopwatch()..start();
    await keeper.pack(i);
    say('keeper ${'abc'[i]} packed partition $i in ${sw.elapsedMilliseconds} ms');
    nodes.add(
      ChainNode(
          params: live,
          genesis: genesis,
          address: addresses[i],
          link: cores[i].net.backend.link,
          secretKey: keys[i],
          keeper: keeper,
          peers: addresses,
        )
        ..anchorBody = (i == 0 ? (_) => log.anchorBody() : null)
        ..log = (m) => logs.writeln('${DateTime.now().difference(t0).inSeconds}s ${'abc'[i]}: $m'),
    );
  }
  for (final n in nodes) {
    n.start();
  }
  // A phone: a second profile on c's device, with its own I2P address,
  // running a light client that follows a and b.
  Set<String> ids(Map s) => {for (final p in s['profiles'] as List) (p as Map)['id'] as String};
  final before = ids(await cores[2].handle('state', {}));
  final lightId = ids(await cores[2].handle('create', {'name': 'phone'})).difference(before).single;
  await cores[2].handle('stayOnline', {'id': lightId, 'on': true});
  String? lightAddress;
  for (var i = 0; i < 180 && lightAddress == null; i++) {
    lightAddress = cores[2].net.addressOf(lightId);
    if (lightAddress == null) await Future<void>.delayed(const Duration(seconds: 1));
  }
  if (lightAddress == null) {
    say('FAILED: the phone\'s address did not come up');
    exit(1);
  }
  final light = LightClient(
    params: live,
    genesisRoot: genesis.rootHex,
    genesisTick: genesis.genesisTick,
    address: lightAddress,
    link: cores[2].net.backend.link,
    peers: [addresses[0], addresses[1]],
  )..log = (m) => logs.writeln('${DateTime.now().difference(t0).inSeconds}s phone: $m');
  light.start();
  say('phone up at ${lightAddress.substring(0, 8)}, following a and b');
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
        'phone: h${light.height} ${light.headHash.isEmpty ? '-' : light.headHash.substring(0, 6)}',
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
      'keeper ${'abc'[i]} declared: ${s.declarations[nodes[i].key] ?? 'dropped'}, '
      'last proof on day ${s.provenOn[nodes[i].key]?[i]}, standing ${(s.standing[nodes[i].key] ?? 0) / ChainParams.grainsPerMarca}',
    );
  }
  final pool = s.circles['commons']!.pool / live.issuanceOn(0);
  say('the pool holds ${pool.toStringAsFixed(4)} days of issuance');
  say(
    'commons anchored at day ${s.dayOf(s.circles['commons']!.anchoredAt)}, log head ${s.circles['commons']!.logHead == log.head ? 'matches' : 'DIFFERS'}',
  );

  // The phone: same head, a proven read, and a bad block dropped.
  for (var i = 0; i < 60 && light.headHash != nodes[0].headHash; i++) {
    await Future<void>.delayed(const Duration(seconds: 1));
  }
  final phoneFollows = light.headHash == nodes[0].headHash;
  say('phone head ${phoneFollows ? 'matches' : 'DIFFERS'} (height ${light.height})');
  var phoneReads = false;
  try {
    final sw = Stopwatch()..start();
    final read = await light.read('circles', ['commons']);
    final pool = CircleState.fromJson(jsonDecode(read['commons']!.value!) as Map).pool;
    phoneReads = pool == s.circles['commons']!.pool;
    say('phone read the pool with a proof in ${sw.elapsedMilliseconds} ms: ${phoneReads ? 'matches' : 'DIFFERS'}');
  } on Object catch (e) {
    say('phone could not read the pool: $e');
  }
  // c turns bad: a block without a mining proof, claiming any state.
  final bad = Block(
    height: s.height + 1,
    prev: nodes[0].headHash,
    tick: nodes[0].currentTick,
    producer: nodes[2].key,
    txs: const [],
    txRoot: Block.txsRoot(const []),
    stateRoot: 'ab' * 32,
    corpusRoot: s.corpusRoot,
    proof: const {},
    sig: '',
    target: s.target,
    traceRoot: Block.traceRootOf([fromHex('ab' * 32)]),
    trace: ['ab' * 32],
  ).signedBy(keys[2]);
  final link = cores[2].net.backend.link;
  await link.send(lightAddress, encodeChainMessage({'t': 'header', 'h': Header.of(bad).toJson()}), from: addresses[2]);
  for (var i = 0; i < 60 && light.headHash != bad.hash; i++) {
    await Future<void>.delayed(const Duration(seconds: 1));
  }
  final took = light.headHash == bad.hash;
  final sw = Stopwatch()..start();
  await link.send(addresses[0], encodeChainMessage({'t': 'block', 'b': bad.toJson()}), from: addresses[2]);
  for (var i = 0; i < 120 && !light.rejected.contains(bad.hash); i++) {
    await Future<void>.delayed(const Duration(seconds: 1));
  }
  final dropped = light.rejected.contains(bad.hash) && light.headHash != bad.hash;
  say(
    'bad block: phone ${took ? 'took it' : 'never took it'}, '
    '${dropped ? 'dropped it on a\'s fraud proof after ${sw.elapsedMilliseconds} ms' : 'did NOT drop it'}',
  );
  await light.stop();

  final ok =
      phoneFollows &&
      phoneReads &&
      dropped &&
      s.circles['commons']!.logHead == log.head &&
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
