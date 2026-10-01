// A seed node: a headless Arca that founds the test network and keeps it
// going (docs/seed-node.md). It shares one collection, which is the
// network's corpus, keeps and proves every partition of it, mines, answers
// at the network's meeting point, and serves the circle log and the files
// to whoever joins.
//
//   dart run tool/seed_node.dart <data dir> [--name=<collection>]
//     [--release=<release.json>] [--release-github] <file>...
//
// The first run creates the collection from the files and starts the test
// network; later runs take no files and pick up where the last one stopped.
// The network's spec goes to <data dir>/spec.json: built into the app
// (TestnetSpec._builtInSpec), it makes every copy of Arca find this network
// by itself. <data dir>/checkpoint.json holds its latest block, to build
// into a release (TestnetSpec._builtInCheckpoint): devices check the chain
// they are shown from there and refuse any chain without it. SIGINT or
// SIGTERM stops it cleanly.
//
// The seed also keeps and serves Arca's newest release over I2P
// (docs/architecture.md, 11): --release names a release.json with the
// downloads beside it (as the release workflow publishes them), read again
// every hour; --release-github fetches the newest release.json and the
// downloads from GitHub over HTTPS every six hours instead. That is an
// explicit choice: a seed is an operator's machine, and the files are
// checked against the release key built into Arca either way.
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
    stderr.writeln(
      'usage: seed_node.dart <data dir> [--name=<collection>] [--release=<release.json>] [--release-github] <file>...',
    );
    exit(64);
  }
  final releaseFile = options['release'];
  final releaseGithub = args.contains('--release-github');
  final dir = rest.first;
  final files = rest.skip(1).toList();
  final core = await CoreService.open(
    '$dir/core',
    startNetwork: false,
    backend: I2pBackend('$dir/core/i2p'),
    defaultBaseFolder: '$dir/Arca',
    // The seed is given its releases; it does not go looking for them.
    updateChecks: false,
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

  // A line a minute, for the service's log, and the head as a checkpoint
  // a release can build in (TestnetSpec._builtInCheckpoint). Lines added to
  // <data dir>/faucet ("<wallet address> <marcas>") are paid privately from
  // the founder's allocation: test marcas for whoever asks.
  final faucet = File('$dir/faucet');
  DateTime? lastRelease;
  while (!stopping) {
    final every = releaseGithub && releaseFile == null ? const Duration(hours: 6) : const Duration(hours: 1);
    if ((releaseFile != null || releaseGithub) &&
        (lastRelease == null || DateTime.now().difference(lastRelease) >= every)) {
      lastRelease = DateTime.now();
      final r = await core.handle('updateImport', {'path': ?releaseFile, 'github': releaseGithub});
      if (r['error'] != null) {
        say('release: ${r['error']}');
      } else {
        final missing = (r['missing'] as List).cast<String>();
        say('release: serving Arca ${r['version']}, ${r['held']} files${missing.isEmpty ? '' : '; missing ${missing.join(', ')}'}');
      }
    }
    if (faucet.existsSync()) {
      final lines = faucet.readAsLinesSync().where((l) => l.trim().isNotEmpty).toList();
      faucet.deleteSync();
      for (final line in lines) {
        final parts = line.trim().split(RegExp(r'\s+'));
        if (parts.length != 2) continue;
        final moved = await core.handle('chainMove', {'amount': parts[1]});
        if (moved['error'] != null) {
          say('faucet: ${moved['error']}');
          continue;
        }
        // Wait for the marcas to be on the private side, then pay.
        for (var i = 0; i < 60; i++) {
          final r = await core.handle('chainSend', {'to': parts[0], 'amount': parts[1]});
          if (r['error'] == null) {
            say('faucet: paid ${parts[1]} marcas to ${parts[0].substring(0, 14)}...');
            break;
          }
          await Future<void>.delayed(const Duration(seconds: 5));
        }
      }
    }
    final cp = await core.handle('chainCheckpoint', {});
    if (cp['anchor'] != null) File('$dir/checkpoint.json').writeAsStringSync(jsonEncode(cp['anchor']));
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
