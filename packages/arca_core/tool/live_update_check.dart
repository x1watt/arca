// Updates over the live I2P network (docs/architecture.md, 11): a seed and
// a device on an older version, each with its own I2P node, as on two
// machines. The seed imports a published release; the device finds it at
// the updates meeting point, downloads its file over I2P, checks it and
// gets it ready to install. Prints what happened and how long it took.
//
//   gh release download v0.1.1 -R x1watt/arca -D <release folder>
//   dart run tool/live_update_check.dart <data dir> <release folder> [--target=android-arm64]
//
// The release is checked against the release key built into Arca. The
// device pretends to run 0.1.0 and never installs anything.
import 'dart:async';
import 'dart:io';

import 'package:arca_core/arca_core.dart';

final t0 = DateTime.now();
String t() => '${DateTime.now().difference(t0).inSeconds}s'.padLeft(6);
void say(String m) => print('${t()}  $m');

Future<void> main(List<String> args) async {
  // earlyoom may send SIGTERM when memory runs low (docs/TODO.md, 3).
  ProcessSignal.sigterm.watch().listen((_) => say('(ignored a SIGTERM)'));
  final rest = args.where((a) => !a.startsWith('--')).toList();
  if (rest.length != 2) {
    stderr.writeln('usage: live_update_check.dart <data dir> <release folder> [--target=<os>-<arch>]');
    exit(64);
  }
  final (dir, release) = (rest[0], rest[1]);
  final targetArg = args.where((a) => a.startsWith('--target=')).map((a) => a.substring(9)).firstOrNull;
  final target = targetArg == null
      ? currentTarget()
      : (os: targetArg.split('-').first, arch: targetArg.split('-').skip(1).join('-'));

  final seed = await CoreService.open(
    '$dir/seed',
    startNetwork: false,
    backend: I2pBackend('$dir/seed/i2p'),
    defaultBaseFolder: '$dir/seed/Arca',
    updateChecks: false,
  );
  final device = await CoreService.open(
    '$dir/device',
    startNetwork: false,
    backend: I2pBackend('$dir/device/i2p'),
    defaultBaseFolder: '$dir/device/Arca',
    appVersion: '0.1.0+1',
    updateTarget: target,
    appDir: '$dir/device/app/arca',
    updateChecks: false,
  );
  say('starting two I2P nodes');
  await Future.wait([seed.net.start(), device.net.start()]);
  if (seed.net.state != NetState.up || device.net.state != NetState.up) {
    say('FAIL I2P did not start');
    exit(1);
  }
  final imported = await seed.handle('updateImport', {'path': '$release/release.json'});
  if (imported['error'] != null) {
    say('FAIL the seed refused the release: ${imported['error']}');
    exit(2);
  }
  say('seed serves Arca ${imported['version']}: ${imported['held']} files, missing ${imported['missing']}');

  Map upd(Map<String, Object?> s) => s['update'] as Map;
  Map? available(Map<String, Object?> s) => upd(s)['available'] as Map?;

  // Leases take a while to spread: ask again until an answer arrives.
  final found = DateTime.now();
  Map<String, Object?> s = {};
  for (var i = 1; i <= 20; i++) {
    await device.handle('updateCheck', {'wait': 30000});
    s = await device.handle('state', {});
    if (available(s) != null && (available(s)!['peers'] as int) > 0) break;
    say('check $i: ${upd(s)['latest'] == null ? 'no answer yet' : 'release known, no source yet'}');
  }
  final av = available(s);
  if (av == null) {
    say('FAIL the device never heard of the release');
    exit(3);
  }
  say(
    'OK   device knows Arca ${av['version']} after ${DateTime.now().difference(found).inSeconds} s; '
    'its file ${av['name']} (${av['size']} bytes) from ${av['peers']} source(s)',
  );

  final fetch = DateTime.now();
  var lastSay = DateTime.now();
  while (DateTime.now().difference(fetch) < const Duration(minutes: 60)) {
    s = await device.handle('state', {});
    final u = upd(s), a = available(s)!;
    if (a['held'] == true && a['install'] != null) break;
    if (u['downloading'] != true && u['staging'] != true && u['error'] != null) {
      say('download stopped: ${u['error']}; trying again');
      await device.handle('updateCheck', {'wait': 20000});
    }
    if (DateTime.now().difference(lastSay) > const Duration(seconds: 30)) {
      lastSay = DateTime.now();
      say('  ${u['received']} of ${a['size']} bytes');
    }
    await Future<void>.delayed(const Duration(seconds: 1));
  }
  final a = available(s)!;
  if (a['held'] != true) {
    say('FAIL the file did not arrive');
    exit(4);
  }
  final secs = DateTime.now().difference(fetch).inMilliseconds / 1000;
  final (sha, _, size) = await hashFile(File(a['path'] as String));
  say(
    'OK   ${a['name']} arrived over I2P in ${secs.toStringAsFixed(0)} s '
    '(${(size / 1024 / secs).toStringAsFixed(0)} KB/s), SHA-256 ${sha == a['sha256'] ? 'matches' : 'DIFFERS'}; '
    'install: ${a['install']}',
  );
  await device.close();
  await seed.close();
  exit(sha == a['sha256'] ? 0 : 5);
}
