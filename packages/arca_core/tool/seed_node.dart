// A seed node: a headless Arca that founds the test network and keeps it
// going (docs/seed-node.md). It shares one collection, which is the
// network's corpus, keeps and proves every partition of it, mines, answers
// at the network's meeting point, and serves the circle log and the files
// to whoever joins.
//
//   dart run tool/seed_node.dart <data dir> [--name=<collection>] <file>...
//
// The first run creates the collection from the files and starts the test
// network; later runs take no files and pick up where the last one stopped.
// The network's spec goes to <data dir>/spec.json: built into the app
// (TestnetSpec._builtInSpec), it makes every copy of Arca find this network
// by itself. SIGINT or SIGTERM stops it cleanly.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:arca_core/arca_core.dart';
import 'package:arca_core/src/chain/params.dart';

void say(String m) => print('${DateTime.now().toUtc().toIso8601String().substring(0, 19)}  $m');

Future<void> main(List<String> args) async {
  final options = {
    for (final a in args.where((a) => a.startsWith('--') && a.contains('=')))
      a.substring(2, a.indexOf('=')): a.substring(a.indexOf('=') + 1),
  };
  final rest = args.where((a) => !a.startsWith('--')).toList();
  if (rest.isEmpty) {
    stderr.writeln('usage: seed_node.dart <data dir> [--name=<collection>] <file>...');
    exit(64);
  }
  final dir = rest.first;
  final files = rest.skip(1).toList();
  final core = await CoreService.open(
    '$dir/core',
    startNetwork: false,
    backend: I2pBackend('$dir/core/i2p'),
    defaultBaseFolder: '$dir/Arca',
  );

  var stopping = false;
  Future<void> stop(ProcessSignal signal) async {
    if (stopping) return;
    stopping = true;
    say('stopping (${signal.name})');
    await core.close();
    exit(0);
  }

  ProcessSignal.sigint.watch().listen(stop);
  ProcessSignal.sigterm.watch().listen(stop);

  // Bootstrapping I2P fails now and then (reseed servers, no peers yet); a
  // service keeps trying, waiting longer each time.
  for (var wait = 30; core.net.state != NetState.up; wait = (wait * 2).clamp(30, 600)) {
    say('starting I2P');
    await core.net.start();
    if (core.net.state == NetState.up) break;
    say('I2P did not start (${core.net.state.name}); trying again in $wait s');
    await Future<void>.delayed(Duration(seconds: wait));
  }
  var s = await core.handle('state', {});
  final me = (s['profiles'] as List).cast<Map>().firstWhere((p) => p['id'] == s['active']);
  say('I2P up; the seed is ${me['arcaAddress']}');

  // The chain resumes by itself once the network is up; give it a moment
  // to say whether this profile already founded one.
  Map? chain;
  for (var i = 0; i < 30 && chain == null; i++) {
    s = await core.handle('state', {});
    chain = s['chain'] as Map?;
    if (chain == null && s['chainPending'] != true) break;
    await Future<void>.delayed(const Duration(seconds: 1));
  }
  if (chain == null) {
    if (files.isEmpty) {
      say('no test network here yet: pass the files of its collection');
      await core.close();
      exit(64);
    }
    await core.handle('rename', {'id': me['id'], 'name': 'Arca seed'});
    final name = options['name'] ?? 'Arca test corpus';
    final col = (await core.handle('createCollection', {'name': name}))['created'] as String;
    await core.handle('addFiles', {'collection': col, 'paths': files});
    say('shared ${files.length} files as "$name"; starting the test network');
    final r = await core.handle('chainStart', {'collection': col});
    if (r['error'] != null) {
      say('could not start the test network: ${r['error']}');
      await core.close();
      exit(1);
    }
  }
  while (chain?['height'] == null) {
    await Future<void>.delayed(const Duration(seconds: 1));
    s = await core.handle('state', {});
    chain = s['chain'] as Map?;
    if (s['chainError'] != null) say('chain: ${s['chainError']}');
  }
  final spec = (await core.handle('chainSpec', {}))['spec'];
  File('$dir/spec.json').writeAsStringSync(jsonEncode(spec));
  say('network ${chain!['spec']}, spec in $dir/spec.json');

  // A line a minute, for the service's log.
  while (!stopping) {
    s = await core.handle('state', {});
    final c = (s['chain'] as Map?) ?? const {};
    say(
      'I2P ${core.net.state.name}, height ${c['height']}, day ${c['day']}, ${c['peers']} peers, '
      'balance ${formatGrains(c['balance'] as int? ?? 0)}${c['behind'] == true ? ', behind' : ''}',
    );
    await Future<void>.delayed(const Duration(minutes: 1));
  }
}

String formatGrains(int grains) => (grains / ChainParams.grainsPerMarca).toStringAsFixed(2);
