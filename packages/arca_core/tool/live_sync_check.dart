// Collection sync, roles and approved changes over the live I2P network:
// three instances, each with its own I2P node, as on three devices.
//
//   dart run tool/live_sync_check.dart [--hours=N] <data dir> <file>...
//
// A (admin) shares the files; F (follower) keeps a copy and suggests a
// change; M (moderator) edits, adds a file and accepts F's suggestion. The
// outsider checks run from F. Prints what happened and how long it took.
//
// With --hours, the three then stay up that long: every ten minutes A adds
// a file and F must copy it, which shows whether sync keeps working as
// tunnels, gateways and leases turn over.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:arca_core/arca_core.dart';
import 'package:arca_core/src/library/collection_index.dart';

final t0 = DateTime.now();
String t() => '${DateTime.now().difference(t0).inSeconds}s'.padLeft(5);
void say(String m) => print('${t()}  $m');

/// Like [waitFor], but reports a miss instead of stopping the run: null
/// when [ok] did not hold within [limit].
Future<Duration?> within(
  CoreService c,
  bool Function(Map<String, Object?>) ok, {
  Duration limit = const Duration(minutes: 10),
}) async {
  final start = DateTime.now();
  var nextPoke = start.add(const Duration(seconds: 30));
  while (DateTime.now().difference(start) < limit) {
    if (ok(await c.handle('state', {}))) return DateTime.now().difference(start);
    if (DateTime.now().isAfter(nextPoke)) {
      await c.handle('refreshFollows', {});
      nextPoke = DateTime.now().add(const Duration(seconds: 30));
    }
    await Future<void>.delayed(const Duration(seconds: 1));
  }
  return null;
}

Future<Map<String, Object?>> waitFor(
  CoreService c,
  bool Function(Map<String, Object?>) ok,
  String what, {
  Duration limit = const Duration(minutes: 10),
  CoreService? poke,
}) async {
  final end = DateTime.now().add(limit);
  var nextPoke = DateTime.now().add(const Duration(seconds: 30));
  while (DateTime.now().isBefore(end)) {
    final s = await c.handle('state', {});
    if (ok(s)) {
      say('OK   $what');
      return s;
    }
    if (DateTime.now().isAfter(nextPoke)) {
      await (poke ?? c).handle('refreshFollows', {});
      nextPoke = DateTime.now().add(const Duration(seconds: 30));
    }
    await Future<void>.delayed(const Duration(seconds: 1));
  }
  say('FAIL $what');
  exit(3);
}

Future<void> main(List<String> args) async {
  // earlyoom may send SIGTERM when memory runs low (docs/TODO.md, 3).
  ProcessSignal.sigterm.watch().listen((_) => say('(ignored a SIGTERM)'));
  final hours = double.parse(
    args.where((a) => a.startsWith('--hours=')).map((a) => a.substring(8)).firstOrNull ?? '0',
  );
  final rest = args.where((a) => !a.startsWith('--')).toList();
  final dir = rest.first;
  final files = rest.skip(1).toList();
  Future<CoreService> open(String name) async {
    final c = await CoreService.open(
      '$dir/$name',
      startNetwork: false,
      backend: I2pBackend('$dir/$name/i2p'),
      defaultBaseFolder: '$dir/$name/Arca',
    );
    return c;
  }

  final a = await open('admin'), m = await open('moderator'), f = await open('follower');
  say('starting three I2P nodes');
  await Future.wait([a.net.start(), m.net.start(), f.net.start()]);
  for (final (n, c) in [('A', a), ('M', m), ('F', f)]) {
    say('$n network: ${c.net.state.name}');
    if (c.net.state != NetState.up) exit(1);
  }
  Future<Map> me(CoreService c) async => ((await c.handle('state', {}))['profiles'] as List).single as Map;
  final aPub = (await me(a))['pubkey'] as String;
  final aAddress = (await me(a))['arcaAddress'] as String, mAddress = (await me(m))['arcaAddress'] as String;

  var s = await a.handle('createCollection', {'name': 'Live test'});
  final col = s['created'] as String;
  await a.handle('addFiles', {'collection': col, 'paths': files});
  final total = files.fold<int>(0, (n, p) => n + File(p).lengthSync());
  say('A shares ${files.length} files, ${(total / 1024).toStringAsFixed(0)} KB');

  Map? colOf(Map<String, Object?> s) {
    final x = (s['following'] as List).cast<Map>().where((x) => x['pubkey'] == aPub);
    return x.isEmpty ? null : (x.single['collections'] as Map)[col] as Map?;
  }

  Map? syncOf(Map<String, Object?> s) =>
      ((s['following'] as List).cast<Map>().where((x) => x['pubkey'] == aPub).firstOrNull?['synced'] as Map?)?[col]
          as Map?;
  List<Map> adminFiles(Map<String, Object?> s) =>
      (((s['collections'] as List).single as Map)['files'] as List).cast<Map>();

  // 1. Keep a copy.
  await f.handle('follow', {'address': aAddress});
  await waitFor(f, (s) => colOf(s) != null, 'F reads the collection from A');
  var t1 = DateTime.now();
  await f.handle('sync', {'owner': aPub, 'collection': col});
  s = await waitFor(
    f,
    (s) => syncOf(s)?['done'] == files.length && syncOf(s)?['running'] == false,
    'F copied every file',
  );
  final secs = DateTime.now().difference(t1).inMilliseconds / 1000;
  say(
    '     ${(total / 1024).toStringAsFixed(0)} KB in ${secs.toStringAsFixed(1)} s = ${(total / 1024 / secs).toStringAsFixed(1)} KB/s',
  );
  final folder = syncOf(s)!['folder'] as String;
  for (final p in files) {
    final name = p.split('/').last;
    final same = File('$folder/$name').readAsBytesSync().toString() == File(p).readAsBytesSync().toString();
    say('     $name identical: $same');
    if (!same) exit(4);
  }

  // 2. Moderator edits.
  await a.handle('setModerators', {
    'collection': col,
    'addresses': [mAddress],
  });
  await m.handle('follow', {'address': aAddress});
  s = await waitFor(m, (s) => ((colOf(s)?['moderators'] as List?) ?? const []).isNotEmpty, 'M sees it is a moderator');
  final first = (colOf(s)!['files'] as List).cast<Map>().first;
  var r = await m.handle('moderate', {
    'owner': aPub,
    'collection': col,
    'ops': [
      {'op': 'edit', 'path': first['path'], 'sha256': first['sha256'], 'title': 'Retitled by the moderator'},
    ],
  });
  say('M edits a title: ${r['error'] ?? 'sent'}');
  await waitFor(a, (s) => adminFiles(s).any((x) => x['title'] == 'Retitled by the moderator'), 'A folded the edit');
  await waitFor(
    f,
    (s) => ((colOf(s)?['files'] as List?) ?? const []).any((x) => (x as Map)['title'] == 'Retitled by the moderator'),
    'F sees the edit',
  );

  // 3. Moderator adds a file.
  final extra = File('$dir/from-moderator.txt')..writeAsStringSync('added by the moderator over I2P\n');
  r = await m.handle('moderate', {
    'owner': aPub,
    'collection': col,
    'addPaths': [extra.path],
  });
  say('M adds a file: ${r['error'] ?? 'sent'}');
  await waitFor(a, (s) => adminFiles(s).any((x) => x['path'] == 'from-moderator.txt'), 'A fetched it from M');
  await waitFor(f, (s) => (syncOf(s)?['files'] as Map?)?.containsKey('from-moderator.txt') == true, 'F copied it');

  // 4. A suggestion approved by the moderator.
  s = await f.handle('state', {});
  final target = (colOf(s)!['files'] as List).cast<Map>().last;
  r = await f.handle('propose', {
    'owner': aPub,
    'collection': col,
    'path': target['path'],
    'sha256': target['sha256'],
    'title': 'Suggested by the follower',
  });
  final id = r['sent'] as String?;
  say('F suggests a title: ${r['error'] ?? 'sent'}');
  if (id == null) exit(5);
  await waitFor(
    m,
    (s) => (s['proposals'] as List).any((p) => (p as Map)['id'] == id),
    'M received the suggestion',
    poke: m,
  );
  r = await m.handle('decide', {'id': id, 'accept': true});
  say('M accepts: ${r['error'] ?? 'done'}');
  await waitFor(
    a,
    (s) => adminFiles(s).any((x) => x['title'] == 'Suggested by the follower'),
    'A has the accepted title',
  );
  await waitFor(
    f,
    (s) => (s['mySuggestions'] as List).any((x) => (x as Map)['id'] == id && x['status'] == 'accepted'),
    'F sees it accepted',
  );

  // 5. F is not a moderator.
  r = await f.handle('moderate', {
    'owner': aPub,
    'collection': col,
    'ops': [
      {'op': 'remove', 'path': target['path'], 'sha256': target['sha256']},
    ],
  });
  say('F tries to remove a file: ${r['error']}');
  final fs = await f.handle('state', {});
  final fId = fs['active'] as String;
  final nsec = (await f.handle('exportNsec', {'id': fId}))['nsec'] as String;
  final forged = NostrEvent.sign(
    secretKey: decodeEntity(nsec, 'nsec'),
    kind: kindCollectionChange,
    content: jsonEncode({
      'ops': [
        {'op': 'remove', 'path': target['path'], 'sha256': target['sha256']},
      ],
    }),
    tags: [
      ['a', '30780:$aPub:$col'],
      ['p', aPub],
    ],
  );
  final aI2p = (await me(a))['i2p'] as String;
  final res = await f.net.nodeOf(fId)!.publish(aI2p, forged, attempts: 3, timeout: const Duration(seconds: 30));
  say('F sends a signed change straight to A\'s relay: accepted=${res.accepted} "${res.message}"');
  final still = adminFiles(await a.handle('state', {})).any((x) => x['path'] == target['path']);
  say('file still in A\'s collection: $still');
  var failed = res.accepted || !still;
  say(failed ? 'FAILED' : 'ALL CHECKS PASSED');

  // 6. Over hours: a new file every ten minutes.
  if (hours > 0 && !failed) {
    final end = DateTime.now().add(Duration(minutes: (hours * 60).round()));
    final took = <int>[];
    var missed = 0, round = 0;
    while (DateTime.now().isBefore(end)) {
      round++;
      final name = 'round-$round.txt';
      final p = File('$dir/$name')..writeAsStringSync('round $round at ${DateTime.now()}\n');
      await a.handle('addFiles', {'collection': col, 'paths': [p.path]});
      final d = await within(f, (s) => (syncOf(s)?['files'] as Map?)?.containsKey(name) == true);
      if (d == null) {
        missed++;
        say('MISS round $round: F did not copy $name within ten minutes');
      } else {
        took.add(d.inSeconds);
        say('OK   round $round: F copied $name in ${d.inSeconds} s');
      }
      final next = DateTime.now().add(const Duration(minutes: 10) - (d ?? const Duration(minutes: 10)));
      while (DateTime.now().isBefore(next) && DateTime.now().isBefore(end)) {
        await Future<void>.delayed(const Duration(seconds: 5));
      }
    }
    took.sort();
    say(
      'over ${hours}h: $round rounds, $missed missed'
      '${took.isEmpty ? '' : ', median ${took[took.length ~/ 2]} s, worst ${took.last} s'}',
    );
    failed = missed > 0;
    say(failed ? 'FAILED' : 'ALL ROUNDS PASSED');
  }
  for (final c in [a, m, f]) {
    await c.close();
  }
  exit(failed ? 6 : 0);
}
