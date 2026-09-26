// Does a profile stay reachable over I2P for long? A (the one reached)
// sits idle; B reaches A's profile address every three minutes for as long
// as asked and reports each attempt. A's I2P log goes to a file.
//
//   dart run tool/reach_check.dart <data dir> <minutes>
import 'dart:io';

import 'package:arca_core/arca_core.dart';

final t0 = DateTime.now();
String t() => '${(DateTime.now().difference(t0).inSeconds / 60).toStringAsFixed(1)}m'.padLeft(6);

Future<void> main(List<String> args) async {
  final dir = args[0];
  final minutes = int.parse(args[1]);
  final logs = File('$dir/a-i2p.log')..parent.createSync(recursive: true);
  final sink = logs.openWrite();
  final a = await CoreService.open(
    '$dir/a',
    startNetwork: false,
    backend: I2pBackend('$dir/a/i2p', log: (m) => sink.writeln('${t()} $m')),
    defaultBaseFolder: '$dir/a/Arca',
  );
  final b = await CoreService.open('$dir/b', startNetwork: false, backend: I2pBackend('$dir/b/i2p'), defaultBaseFolder: '$dir/b/Arca');
  await Future.wait([a.net.start(), b.net.start()]);
  print('${t()} networks: ${a.net.state.name}, ${b.net.state.name}');
  final me = ((await a.handle('state', {}))['profiles'] as List).single as Map;
  await a.handle('rename', {'id': me['id'], 'name': 'Reach test'});
  final address = me['arcaAddress'] as String;
  await b.handle('follow', {'address': address});
  final end = t0.add(Duration(minutes: minutes));
  var round = 0;
  while (DateTime.now().isBefore(end)) {
    round++;
    final sw = Stopwatch()..start();
    await b.handle('refreshFollows', {});
    Map? f;
    for (var i = 0; i < 90; i++) {
      final s = await b.handle('state', {});
      f = (s['following'] as List).cast<Map>().firstOrNull;
      if (f != null && f['refreshing'] != true && sw.elapsed.inSeconds > 2) break;
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    final ok = f != null && f['error'] == null && (f['name'] as String? ?? '') == 'Reach test';
    print('${t()} round $round: ${ok ? 'reached' : 'NOT reached (${f?['error']})'} in ${sw.elapsed.inSeconds}s');
    await Future<void>.delayed(const Duration(minutes: 3));
  }
  await sink.close();
  await a.close();
  await b.close();
  exit(0);
}
