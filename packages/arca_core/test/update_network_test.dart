// Updates over the network (docs/architecture.md, 11), on an in-process
// network: a seed takes a signed release from a folder and serves it; a
// desktop running an older version finds it at the updates meeting point,
// downloads it in chunks, checks it and unpacks it beside its app; a
// second desktop gets it from the first while the seed is away; a phone
// gets its APK. A device answering with a forged announcement or wrong
// bytes gets nowhere.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:arca_core/arca_core.dart';
import 'package:arca_core/src/transport/blobs.dart';
import 'package:arca_core/src/update/store.dart';
import 'package:i2p/i2p.dart' show sharedDestinationAddress;
import 'package:test/test.dart';

import 'update_test.dart' show fakeArchive, fakeBundle;

final releaseSecret = generateSecretKey(Random(21));
final releaseKey = toHex(publicKeyOf(releaseSecret));

Future<Map<String, Object?>> waitFor(CoreService c, bool Function(Map<String, Object?> s) ok, String what) async {
  Map<String, Object?> s = {};
  final end = DateTime.now().add(const Duration(seconds: 60));
  while (DateTime.now().isBefore(end)) {
    s = await c.handle('state', {});
    if (ok(s)) return s;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  throw StateError('condition not reached: $what; update: ${s['update']}');
}

Map upd(Map<String, Object?> s) => s['update'] as Map;
Map? available(Map<String, Object?> s) => upd(s)['available'] as Map?;

void main() {
  late Directory tmp;
  setUp(() async => tmp = await Directory.systemTemp.createTemp('arca_update_net'));
  tearDown(() async => tmp.delete(recursive: true));

  /// A folder as the release workflow leaves it: the five downloads and
  /// release.json, signed by the test release key. The Linux download is a
  /// real archive of a fake bundle, with 120 KB that do not compress.
  Future<(String, NostrEvent)> releaseFolder(String version) async {
    final dist = Directory('${tmp.path}/dist')..createSync();
    final linux = await fakeArchive(tmp.path, 'new', noise: 120 * 1024);
    await linux.copy('${dist.path}/arca-linux-x64.tar.gz');
    final rng = Random(3);
    for (final n in releaseAssetNames.keys.where((n) => !n.contains('linux'))) {
      File('${dist.path}/$n').writeAsBytesSync(List.generate(30 * 1024 + rng.nextInt(1000), (_) => rng.nextInt(256)));
    }
    final assets = <ReleaseAsset>[];
    for (final MapEntry(key: n, value: t) in releaseAssetNames.entries) {
      final (sha, _, size) = await hashFile(File('${dist.path}/$n'));
      assets.add(ReleaseAsset(name: n, os: t.os, arch: t.arch, size: size, sha256: sha));
    }
    final e = signRelease(secretKey: releaseSecret, version: AppVersion.parse(version), assets: assets, notes: 'New.');
    File('${dist.path}/release.json').writeAsStringSync(jsonEncode(e.toJson()));
    return ('${dist.path}/release.json', e);
  }

  Future<CoreService> open(LoopbackNetwork net, String name, {String version = '0.1.0+1', Target? target}) async {
    final app = await fakeBundle('${tmp.path}/$name/app/arca', version);
    final c = await CoreService.open(
      '${tmp.path}/$name/data',
      cost: VaultCost.test,
      backend: LoopbackBackend(net),
      startNetwork: false,
      defaultBaseFolder: '${tmp.path}/$name/Arca',
      releaseKey: releaseKey,
      appVersion: version,
      updateTarget: target ?? (os: 'linux', arch: 'x64'),
      appDir: app.path,
      updateChecks: false,
    );
    await c.net.start();
    return c;
  }

  Future<String> addressOf(CoreService c) async =>
      (((await c.handle('state', {}))['profiles'] as List).single as Map)['i2p'] as String;

  test('a seed serves a release; desktops and a phone find, fetch, check and stage it', () async {
    final net = LoopbackNetwork();
    final (path, event) = await releaseFolder('0.2.0+3');
    final seed = await open(net, 'seed', version: '0.2.0+3');
    final imported = await seed.handle('updateImport', {'path': path});
    expect(imported['error'], isNull);
    expect(imported['held'], 5);
    expect(imported['missing'], isEmpty);
    final seedState = await seed.handle('state', {});
    expect(upd(seedState)['latest'], '0.2.0');
    expect(available(seedState), isNull, reason: 'the seed runs that version already');

    // The seed keeps the announcement in its relay for anyone who asks.
    final a = await open(net, 'desktop-a');
    final aNode = a.net.nodeOf(a.net.onlineIds.single)!;
    final kept = await aNode.query(await addressOf(seed), [
      NostrFilter(kinds: const [Kind.arcaRelease], authors: [releaseKey]),
    ]);
    expect(kept.map((e) => e.id), [event.id]);

    // A desktop on 0.1.0 checks: the seed answers at the meeting point,
    // the file comes over the network, is checked and unpacked.
    expect(available(await a.handle('state', {})), isNull);
    final checked = await a.handle('updateCheck', {'wait': 600});
    expect(checked['error'], isNull);
    var s = await waitFor(a, (s) => available(s)?['install'] == 'restart', 'desktop A staged the update');
    final av = available(s)!;
    expect(av['version'], '0.2.0');
    expect(av['name'], 'arca-linux-x64.tar.gz');
    expect(av['held'], isTrue);
    expect(upd(s)['source'], 'i2p');
    expect(upd(s)['error'], isNull);
    expect(File('${tmp.path}/desktop-a/app/.arca-update/arca/version').readAsStringSync(), 'new');
    expect(File('${tmp.path}/desktop-a/app/arca/version').readAsStringSync(), '0.1.0+1', reason: 'not swapped');
    // Only its own platform's file was fetched.
    expect(upd(s)['serving'], 1);

    // A second desktop gets it from the first while the seed is away.
    net.setOnline(await addressOf(seed), false);
    final b = await open(net, 'desktop-b');
    await b.handle('updateCheck', {'wait': 600});
    s = await waitFor(b, (s) => available(s)?['install'] == 'restart', 'desktop B staged the update from A');
    expect(File('${tmp.path}/desktop-b/app/.arca-update/arca/version').readAsStringSync(), 'new');
    net.setOnline(await addressOf(seed), true);

    // A phone gets its APK, and installing hands it to the system.
    final phone = await open(net, 'phone', target: (os: 'android', arch: 'arm64'));
    await phone.handle('updateCheck', {'wait': 600});
    s = await waitFor(phone, (s) => available(s)?['install'] == 'apk', 'the phone holds its APK');
    expect(available(s)!['name'], 'arca-android-arm64.apk');
    final install = await phone.handle('updateInstall', {});
    expect(install['apk'], endsWith('/updates/arca-android-arm64.apk'));
    final (sha, _, _) = await hashFile(File(install['apk'] as String));
    expect(sha, available(s)!['sha256']);

    // Notify only: a device that is told so does not download.
    final quiet = await open(net, 'quiet');
    await quiet.handle('updateMode', {'mode': 'notify'});
    await quiet.handle('updateCheck', {'wait': 600});
    s = await quiet.handle('state', {});
    expect(available(s)!['version'], '0.2.0');
    expect(available(s)!['held'], isFalse);
    expect(upd(s)['downloading'], isFalse);

    // Never a downgrade: a device on a newer version sees nothing to do.
    final newer = await open(net, 'newer', version: '0.3.0+1');
    await newer.handle('updateCheck', {'wait': 600});
    s = await newer.handle('state', {});
    expect(upd(s)['latest'], '0.2.0');
    expect(available(s), isNull);
    expect(await newer.handle('updateInstall', {}), containsPair('error', isA<String>()));

    for (final c in [seed, a, b, phone, quiet, newer]) {
      await c.close();
    }
  });

  test('forged announcements and wrong bytes get nowhere', () async {
    final net = LoopbackNetwork();
    final (_, event) = await releaseFolder('0.2.0+3');
    final linux = Release.verify(event, key: releaseKey).assetFor((os: 'linux', arch: 'x64'))!;
    final (enc, sign) = updateMeetingSeeds(releaseKey);
    final meeting = await sharedDestinationAddress(enc, sign);

    // A liar at the meeting point: first a release signed by its own key,
    // then the real announcement (it is public) with bytes of its own.
    const liar = 'liarliarliarliarliarliarliarliarliarliarliarliarliar.b32.i2p';
    final link = net.link([liar, meeting]);
    final wrong = File('${tmp.path}/wrong')..writeAsBytesSync(List.filled(linux.size, 7));
    final serve = BlobService(address: liar, link: link, resolve: (_) async => wrong.path);
    var answer = signRelease(
      secretKey: generateSecretKey(),
      version: AppVersion.parse('9.0.0+1'),
      assets: [linux],
    );
    final sub = link.incoming.where((m) => m.bytes.length == 1 && m.bytes[0] == updateQueryTag).listen((m) {
      unawaited(link.send(m.from, encodeUpdateAnswer(answer, [linux.sha256]), from: liar));
    });

    final c = await open(net, 'victim');
    await c.handle('updateCheck', {'wait': 300});
    var s = await c.handle('state', {});
    expect(upd(s)['latest'], isNull, reason: 'a release signed by another key is ignored');
    expect(available(s), isNull);

    answer = event;
    await Future<void>.delayed(const Duration(seconds: 11)); // the liar answers again after ten seconds
    await c.handle('updateCheck', {'wait': 300});
    s = await waitFor(c, (s) => upd(s)['error'] != null, 'the download failed');
    expect(upd(s)['error'], contains('does not match'));
    expect(upd(s)['offerGithub'], isTrue);
    expect(available(s)!['held'], isFalse);
    expect(File('${tmp.path}/victim/data/updates/arca-linux-x64.tar.gz').existsSync(), isFalse);
    expect(Directory('${tmp.path}/victim/app/.arca-update').existsSync(), isFalse);

    await sub.cancel();
    await serve.close();
    await c.close();
  });
}
