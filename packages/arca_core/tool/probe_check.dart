// Does a profile's probe to itself come back over the live I2P network
// (docs/performance.md, 3.17)? A healthy node must never be restarted by
// the watchdog. Probes every 30 s for as long as asked and reports each.
//
//   dart run tool/probe_check.dart <data dir> <minutes>
import 'dart:io';

import 'package:arca_core/arca_core.dart';

final t0 = DateTime.now();
String t() => '${(DateTime.now().difference(t0).inSeconds / 60).toStringAsFixed(1)}m'.padLeft(6);

Future<void> main(List<String> args) async {
  final dir = args[0];
  final minutes = int.parse(args[1]);
  final c = await CoreService.open(
    '$dir/core',
    startNetwork: false,
    backend: I2pBackend('$dir/core/i2p'),
    defaultBaseFolder: '$dir/Arca',
  );
  c.net
    ..probeEvery = const Duration(seconds: 30)
    ..probeWait = const Duration(seconds: 90);
  await c.net.start();
  print('${t()} network ${c.net.state.name}');
  if (c.net.state != NetState.up) exit(1);
  var seen = 0;
  final end = t0.add(Duration(minutes: minutes));
  while (DateTime.now().isBefore(end)) {
    await Future<void>.delayed(const Duration(seconds: 5));
    final n = c.net;
    if (n.probesSent != seen) {
      seen = n.probesSent;
      // Printed when the next probe starts, so the last one has settled.
      print(
        '${t()} probes ${n.probesBack}/${n.probesSent - 1} back, last took '
        '${n.lastProbe?.inMilliseconds ?? '-'} ms, restarts ${n.restarts}',
      );
    }
  }
  final n = c.net;
  print('${t()} done: ${n.probesBack} of ${n.probesSent} probes came back, ${n.restarts} restarts');
  await c.close();
  exit(n.restarts == 0 ? 0 : 2);
}
