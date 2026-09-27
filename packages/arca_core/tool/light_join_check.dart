// A light device joins a test network by invite, follows it, restarts and
// must follow it again (the C61 once stayed at "block 0" after an update).
//
//   dart run tool/light_join_check.dart <data dir> <invite> <minutes each>
import 'dart:io';

import 'package:arca_core/arca_core.dart';

final t0 = DateTime.now();
String t() => '${DateTime.now().difference(t0).inSeconds}s'.padLeft(6);

Future<CoreService> open(String dir) async {
  final c = await CoreService.open(
    '$dir/core',
    startNetwork: false,
    backend: I2pBackend('$dir/core/i2p'),
    defaultBaseFolder: '$dir/Arca',
  );
  await c.net.start();
  print('${t()} network ${c.net.state.name}');
  return c;
}

Future<int> follow(CoreService c, int minutes) async {
  final end = DateTime.now().add(Duration(minutes: minutes));
  var height = 0;
  while (DateTime.now().isBefore(end)) {
    await Future<void>.delayed(const Duration(seconds: 30));
    final s = await c.handle('state', {});
    final chain = (s['chain'] as Map?) ?? const {};
    height = chain['height'] as int? ?? 0;
    print('${t()} height $height, peers ${chain['peers']}, behind ${chain['behind']}, '
        'error ${s['chainError']}, probes ${c.net.probesBack}/${c.net.probesSent}');
  }
  return height;
}

Future<void> main(List<String> args) async {
  final dir = args[0], invite = args[1], minutes = int.parse(args[2]);
  var c = await open(dir);
  final r = await c.handle('chainJoin', {'invite': invite, 'light': true});
  print('${t()} join: ${r['error'] ?? 'ok'}');
  if (r['error'] != null) {
    await c.close();
    exit(1);
  }
  final first = await follow(c, minutes);
  await c.close();
  print('${t()} restarting');
  c = await open(dir);
  final second = await follow(c, minutes);
  await c.close();
  final ok = first > 0 && second > first;
  print(ok ? 'PASSED: followed before and after a restart' : 'FAILED: heights $first then $second');
  exit(ok ? 0 : 1);
}
