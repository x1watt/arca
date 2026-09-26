// End-to-end over the live I2P network: two profiles on one node, each with
// its own destination and relay. Profile A writes its kind 0; profile B
// fetches it from A's address through real tunnels.
//
//   dart run tool/live_i2p_check.dart [data dir]
import 'dart:io';

import 'package:arca_core/arca_core.dart';

Future<void> main(List<String> args) async {
  final dir = args.isNotEmpty ? args.first : (await Directory.systemTemp.createTemp('arca_live')).path;
  final t0 = DateTime.now();
  String t() => '${DateTime.now().difference(t0).inSeconds}s';
  final core = await CoreService.open(
    dir,
    startNetwork: false,
    backend: I2pBackend('$dir/i2p', log: (m) => stdout.writeln('  [i2p ${t()}] $m')),
  );
  var s = await core.handle('create', {'name': 'B'});
  final ids = [for (final p in s['profiles'] as List) (p as Map)['id'] as String];
  await core.handle('stayOnline', {'id': ids[1], 'on': true});
  print('${t()} starting I2P');
  await core.net.start();
  print('${t()} network: ${core.net.state.name} ${core.net.error ?? ''}');
  if (core.net.state != NetState.up) exit(1);
  await core.handle('rename', {'id': ids[0], 'name': 'Live A'});
  final a = core.net.nodeOf(ids[0])!, b = core.net.nodeOf(ids[1])!;
  print('${t()} A=${a.address}\n     B=${b.address}');
  // Lease sets need a moment to reach the floodfills.
  for (var attempt = 1; attempt <= 6; attempt++) {
    print('${t()} B queries A, attempt $attempt');
    final got = await b.query(a.address, [
      const NostrFilter(kinds: [0]),
    ], timeout: const Duration(seconds: 45));
    if (got.isNotEmpty) {
      print('${t()} SUCCESS: got "${got.single.content}", signature valid: ${got.single.verify()}');
      await core.close();
      exit(0);
    }
    await Future<void>.delayed(const Duration(seconds: 20));
  }
  print('${t()} FAILED: no answer from A over I2P');
  await core.close();
  exit(2);
}
