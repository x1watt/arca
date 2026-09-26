// The wallet flow over the live I2P network, as two devices run it: A
// starts a test network from a collection, B joins with A's invite (the
// spec, the founder's collection and every chain message over I2P), both
// keep and prove the corpus, and A pays B.
//
//   dart run tool/live_wallet_check.dart <data dir> <file>...
import 'dart:io';

import 'package:arca_core/arca_core.dart';
import 'package:arca_core/src/chain/params.dart';

/// One-minute days, so a run shows proofs.
const live = ChainParams(
  name: 'arca-live-wallet',
  partitionChunks: 256,
  tickMillis: 1000,
  dayTicks: 60,
  blockTicks: 5,
  packMemoryKiB: 32768,
  dailyIssuance: 100000 * ChainParams.grainsPerMarca,
  halvingDays: 30,
  floorIssuance: 1000 * ChainParams.grainsPerMarca,
  circleFee: 0,
  fraudWindowTicks: 60,
);

final t0 = DateTime.now();
void say(String m) => print('${DateTime.now().difference(t0).inSeconds.toString().padLeft(4)}s  $m');

Future<Map<String, Object?>> waitFor(CoreService c, bool Function(Map s) ok, String what, {int minutes = 10}) async {
  final end = DateTime.now().add(Duration(minutes: minutes));
  Map<String, Object?> s = {};
  while (DateTime.now().isBefore(end)) {
    s = await c.handle('state', {});
    if (ok(s)) {
      say('OK   $what');
      return s;
    }
    await Future<void>.delayed(const Duration(seconds: 1));
  }
  say('FAIL $what (chain: ${s['chain']}, error: ${s['chainError']})');
  exit(2);
}

Map chainOf(Map s) => (s['chain'] as Map?) ?? const {};
bool ready(Map s) {
  final parts = (chainOf(s)['partitions'] as List?)?.cast<Map>() ?? const [];
  return parts.isNotEmpty && parts.every((p) => p['declared'] == true);
}

Future<void> main(List<String> args) async {
  final dir = args.first;
  final cores = <CoreService>[];
  for (final n in ['a', 'b']) {
    final c = await CoreService.open(
      '$dir/$n',
      startNetwork: false,
      backend: I2pBackend('$dir/$n/i2p'),
      defaultBaseFolder: '$dir/$n/Arca',
    );
    cores.add(c);
  }
  final [a, b] = cores;
  say('starting two I2P nodes');
  await Future.wait([a.net.start(), b.net.start()]);
  for (final c in cores) {
    for (var i = 2; c.net.state != NetState.up && i <= 3; i++) {
      await c.net.start();
    }
    if (c.net.state != NetState.up) {
      say('FAIL an I2P node did not start');
      exit(1);
    }
  }
  say('network up');
  final col = (await a.handle('createCollection', {'name': 'Live corpus'}))['created'] as String;
  await a.handle('addFiles', {'collection': col, 'paths': args.skip(1).toList()});
  var sw = Stopwatch()..start();
  var r = await a.handle('chainStart', {'collection': col, 'params': live.toJson()});
  if (r['error'] != null) {
    say('FAIL start: ${r['error']}');
    exit(2);
  }
  final sa = await waitFor(a, ready, 'A packed and declared');
  say('A was ready ${sw.elapsed.inSeconds} s after starting');
  final invite = chainOf(sa)['invite'] as String;
  say('invite ${invite.substring(0, 30)}...');

  sw = Stopwatch()..start();
  r = await b.handle('chainJoin', {'invite': invite});
  if (r['error'] != null) {
    say('FAIL join: ${r['error']}');
    exit(2);
  }
  say('B fetched the spec and the collection index in ${sw.elapsed.inSeconds} s');
  await waitFor(b, ready, 'B copied, rebuilt the corpus, packed and declared');
  say('B joined in ${sw.elapsed.inSeconds} s');

  final bNpub = (((await b.handle('state', {}))['profiles'] as List).single as Map)['npub'];
  sw = Stopwatch()..start();
  await a.handle('chainSend', {'to': bNpub, 'amount': '5'});
  await waitFor(b, (s) => chainOf(s)['balance'] == 5 * ChainParams.grainsPerMarca, 'B received 5 marcas');
  say('payment took ${sw.elapsed.inSeconds} s');
  await waitFor(b, (s) => (chainOf(s)['syncScore'] as int? ?? 0) > 0, 'B proved its keeping', minutes: 4);
  final heights = [for (final c in cores) chainOf(await c.handle('state', {}))['height']];
  say('heights $heights');
  say('ALL CHECKS PASSED');
  for (final c in cores) {
    await c.close();
  }
  exit(0);
}
