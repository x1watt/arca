// Updates of Arca (docs/architecture.md, 11): versions, the signed release
// announcement and what is refused, the updates folder, unpacking, and the
// Linux swap script run for real on throwaway folders.
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:arca_core/arca_core.dart';
import 'package:arca_core/src/update/install.dart';
import 'package:arca_core/src/update/store.dart';
import 'package:test/test.dart';

final key = generateSecretKey(Random(11));
final keyHex = toHex(publicKeyOf(key));

ReleaseAsset asset(String name, {int size = 10, String? sha}) {
  final t = releaseAssetNames[name]!;
  return ReleaseAsset(name: name, os: t.os, arch: t.arch, size: size, sha256: sha ?? 'ab' * 32);
}

NostrEvent announce({String version = '0.2.0+3', List<ReleaseAsset>? assets, List<int>? by, int? at}) => signRelease(
  secretKey: by ?? key,
  version: AppVersion.parse(version),
  assets: assets ?? [for (final n in releaseAssetNames.keys) asset(n)],
  notes: 'Better things.',
  createdAt: at,
);

/// [e] with its contents replaced, keeping the old id and signature.
NostrEvent withContent(NostrEvent e, String content, {List<List<String>>? tags}) => NostrEvent(
  id: e.id,
  pubkey: e.pubkey,
  createdAt: e.createdAt,
  kind: e.kind,
  tags: tags ?? e.tags,
  content: content,
  sig: e.sig,
);

/// [e] with its contents replaced and signed again by [by].
NostrEvent resigned(NostrEvent e, String content, {List<int>? by, int? kind, List<List<String>>? tags}) =>
    NostrEvent.sign(secretKey: by ?? key, kind: kind ?? e.kind, content: content, tags: tags ?? e.tags);

void main() {
  group('versions', () {
    test('parse and order', () {
      final v = AppVersion.parse('0.1.1+2');
      expect((v.major, v.minor, v.patch, v.build), (0, 1, 1, 2));
      expect(v.name, '0.1.1');
      expect(AppVersion.parse('0.1.1').build, 0);
      expect(AppVersion.parse('0.1.10') > AppVersion.parse('0.1.9'), isTrue);
      expect(AppVersion.parse('1.0.0') > AppVersion.parse('0.99.99+999'), isTrue);
      expect(AppVersion.parse('0.1.1+3') > AppVersion.parse('0.1.1+2'), isTrue);
      expect(AppVersion.parse('0.1.1+2') == AppVersion.parse('0.1.1+2'), isTrue);
      expect(AppVersion.parse('0.1.0+9') < AppVersion.parse('0.1.1+1'), isTrue);
      for (final bad in ['', '1', '1.2', '1.2.3.4', 'v1.2.3', '1.2.3+', '1.2.x', '-1.2.3']) {
        expect(AppVersion.tryParse(bad), isNull, reason: bad);
      }
    });

    test('the version built into the core is the app pubspec version', () {
      final line = File('../../app/pubspec.yaml').readAsLinesSync().firstWhere((l) => l.startsWith('version:'));
      expect(AppVersion.parse(line.substring(8).trim()), AppVersion.parse(arcaVersion));
      final core = File('pubspec.yaml').readAsLinesSync().firstWhere((l) => l.startsWith('version:'));
      expect(core.substring(8).trim(), AppVersion.current.name);
    });

    test('the changelog has notes for this version', () {
      final notes = changelogSection(File('../../CHANGELOG.md').readAsStringSync(), AppVersion.current.name);
      expect(notes, isNotEmpty);
      expect(notes.length, lessThan(6000));
    });

    test('changelog sections', () {
      const log = '# Changelog\n\n## 0.2.0 (2026-11-01)\n\n- New.\n- More.\n\n## 0.1.0\n\n- Old.\n';
      expect(changelogSection(log, '0.2.0'), '- New.\n- More.');
      expect(changelogSection(log, '0.1.0'), '- Old.');
      expect(changelogSection(log, '0.3.0'), '');
    });
  });

  group('announcement', () {
    test('a signed release checks and names a file per platform', () {
      final r = Release.verify(announce(), key: keyHex);
      expect(r.version, AppVersion.parse('0.2.0+3'));
      expect(r.tag, 'v0.2.0');
      expect(r.notes, 'Better things.');
      expect(r.assets, hasLength(5));
      expect(r.assetFor((os: 'linux', arch: 'x64'))!.name, 'arca-linux-x64.tar.gz');
      expect(r.assetFor((os: 'windows', arch: 'x64'))!.name, 'arca-windows-x64.zip');
      expect(r.assetFor((os: 'android', arch: 'arm64'))!.name, 'arca-android-arm64.apk');
      expect(r.assetFor((os: 'android', arch: 'arm'))!.name, 'arca-android-armv7.apk');
      expect(r.assetFor((os: 'android', arch: 'x64'))!.name, 'arca-android-x86_64.apk');
      expect(r.assetFor((os: 'macos', arch: 'arm64')), isNull);
      expect(r.assetFor(null), isNull);
      final a = r.assetFor((os: 'linux', arch: 'x64'))!;
      expect(a.content, 'arca:sha256:${a.sha256}');
      expect(
        r.githubUrl(a).toString(),
        'https://github.com/x1watt/arca/releases/download/v0.2.0/arca-linux-x64.tar.gz',
      );
      if (Platform.isLinux) expect(currentTarget(), (os: 'linux', arch: 'x64'));
    });

    test('the trusted key in the app is a valid public key', () {
      expect(isHex(trustedReleaseKey, 32), isTrue);
      expect(npubEncode(fromHex(trustedReleaseKey)), 'npub1nx3aj0y25edc4y3ll98z6dgkqe02a8waj5x5ar505x4mh598zfcq57dzws');
      // A release signed by another key is refused by the built-in key.
      expect(() => Release.verify(announce()), throwsA(isA<ReleaseException>()));
    });

    test('tampered or foreign announcements are refused', () {
      final good = announce();
      final json = jsonDecode(good.content) as Map;
      Matcher refused(String why) =>
          throwsA(isA<ReleaseException>().having((e) => e.message, 'message', contains(why)));

      // Changed after signing: the id no longer matches.
      final tampered = jsonEncode({
        ...json,
        'assets': [
          for (final a in json['assets'] as List) {...(a as Map), 'sha256': 'cd' * 32, 'content': 'arca:sha256:${'cd' * 32}'},
        ],
      });
      expect(() => Release.verify(withContent(good, tampered), key: keyHex), refused('bad signature'));
      // Signed by someone else.
      expect(() => Release.verify(announce(by: generateSecretKey()), key: keyHex), refused('release key'));
      // Another kind or channel by the right key.
      expect(() => Release.verify(resigned(good, good.content, kind: 1), key: keyHex), refused('kind'));
      expect(
        () => Release.verify(
          resigned(good, good.content, tags: [
            ['d', 'arca/release/beta'],
            ['version', '0.2.0'],
          ]),
          key: keyHex,
        ),
        refused('channel'),
      );
      // Contents that do not hold together, even when signed.
      String content(Map<String, Object?> changes) => jsonEncode({...json, ...changes});
      expect(() => Release.verify(resigned(good, content({'version': '0.3.0'})), key: keyHex), refused('version tag'));
      expect(() => Release.verify(resigned(good, content({'version': 'soon'})), key: keyHex), refused('bad version'));
      expect(() => Release.verify(resigned(good, content({'tag': 'v9.9.9'})), key: keyHex), refused('tag'));
      expect(() => Release.verify(resigned(good, content({'assets': []})), key: keyHex), refused('no files'));
      expect(() => Release.verify(resigned(good, 'not json'), key: keyHex), refused('unreadable'));
      expect(() => Release.verify(resigned(good, content({'notes': 'x' * 7000})), key: keyHex), refused('notes'));
      Map<String, Object?> linux(Map<String, Object?> changes) => {
        ...asset('arca-linux-x64.tar.gz').toJson(),
        ...changes,
      };
      for (final (bad, why) in [
        (linux({'name': '../../.bashrc'}), 'bad file name'),
        (linux({'name': 'arca/../x.apk'}), 'bad file name'),
        (linux({'os': 'android'}), 'named for linux/x64'),
        (linux({'sha256': 'xyz'}), 'bad SHA-256'),
        (linux({'size': -1}), 'bad size'),
        (linux({'content': 'arca:sha256:${'00' * 32}'}), 'content address'),
      ]) {
        expect(
          () => Release.verify(
            resigned(good, content({
              'assets': [bad],
            })),
            key: keyHex,
          ),
          refused(why),
          reason: why,
        );
      }
      expect(
        () => Release.verify(
          resigned(good, content({
            'assets': [linux({}), linux({})],
          })),
          key: keyHex,
        ),
        refused('twice'),
      );
    });

    test('newer means a higher version, or the same one announced later', () {
      final a = Release.verify(announce(version: '0.2.0+3', at: 1000), key: keyHex);
      final b = Release.verify(announce(version: '0.2.0+3', at: 2000), key: keyHex);
      final c = Release.verify(announce(version: '0.1.9+9', at: 3000), key: keyHex);
      expect(a.newerThan(null), isTrue);
      expect(b.newerThan(a), isTrue);
      expect(a.newerThan(b), isFalse);
      expect(c.newerThan(a), isFalse);
      expect(a.newerThan(a), isFalse);
    });

    test('the wire carries an announcement and the files held', () {
      final e = announce();
      final (back, have) = decodeUpdateAnswer(encodeUpdateAnswer(e, ['ab' * 32]))!;
      expect(back.id, e.id);
      expect(back.verify(), isTrue);
      expect(have, {'ab' * 32});
      expect(decodeUpdateAnswer(Uint8List.fromList([updateAnswerTag, 1, 2])), isNull);
      expect(decodeUpdateAnswer(updateQuery), isNull);
      // An answer fits in one I2P message even with the longest notes.
      final long = signRelease(
        secretKey: key,
        version: AppVersion.parse('0.2.0+3'),
        assets: [for (final n in releaseAssetNames.keys) asset(n)],
        notes: 'n' * 6000,
      );
      expect(encodeUpdateAnswer(long, [for (final _ in releaseAssetNames.keys) 'ab' * 32]).length, lessThan(30 * 1024));
    });
  });

  group('updates folder', () {
    late Directory tmp;
    setUp(() async => tmp = await Directory.systemTemp.createTemp('arca_update'));
    tearDown(() async => tmp.delete(recursive: true));

    Future<(ReleaseAsset, File)> fileFor(String name, String text) async {
      final f = File('${tmp.path}/src-$name')..writeAsStringSync(text);
      final (sha, _, size) = await hashFile(f);
      final t = releaseAssetNames[name]!;
      return (ReleaseAsset(name: name, os: t.os, arch: t.arch, size: size, sha256: sha), f);
    }

    test('keeps the newest release only, and only files that match', () async {
      final store = UpdateStore('${tmp.path}/updates', key: keyHex);
      await store.load();
      expect(store.release, isNull);
      final (linux, linuxSrc) = await fileFor('arca-linux-x64.tar.gz', 'linux 1');
      final (apk, apkSrc) = await fileFor('arca-android-arm64.apk', 'apk 1');
      final r1 = Release.verify(announce(version: '0.2.0+3', assets: [linux, apk]), key: keyHex);
      expect(await store.adopt(r1), isTrue);
      expect(await store.adopt(r1), isFalse);
      expect(await store.importFile(linux, linuxSrc), isTrue);
      expect(store.pathOf(linux.sha256), store.fileOf(linux).path);
      // Bytes that are not the announced ones are refused.
      final fake = File('${tmp.path}/fake')..writeAsStringSync('apk 2');
      expect(await store.importFile(apk, fake), isFalse);
      expect(store.holds(apk.sha256), isFalse);
      expect(await store.importFile(apk, apkSrc), isTrue);

      // Read back as it was.
      final again = UpdateStore('${tmp.path}/updates', key: keyHex);
      await again.load();
      expect(again.release!.event.id, r1.event.id);
      expect(again.held.toSet(), {linux.sha256, apk.sha256});

      // An older release is not taken; a newer one replaces the files.
      final older = Release.verify(announce(version: '0.1.5+1', assets: [linux]), key: keyHex);
      expect(await again.adopt(older), isFalse);
      final (linux2, linux2Src) = await fileFor('arca-linux-x64.tar.gz', 'linux 2');
      final r2 = Release.verify(announce(version: '0.3.0+4', assets: [linux2]), key: keyHex);
      expect(await again.adopt(r2), isTrue);
      expect(again.held, isEmpty);
      expect(File('${tmp.path}/updates/arca-android-arm64.apk').existsSync(), isFalse);
      expect(File('${tmp.path}/updates/arca-linux-x64.tar.gz').existsSync(), isFalse);
      expect(await again.importFile(linux2, linux2Src), isTrue);

      // A release signed by another key on disk is not loaded.
      File('${tmp.path}/other/release.json')
        ..createSync(recursive: true)
        ..writeAsStringSync(jsonEncode(announce(by: generateSecretKey()).toJson()));
      final other = UpdateStore('${tmp.path}/other', key: keyHex);
      await other.load();
      expect(other.release, isNull);
    });

    test('a release archive is unpacked beside the app', () async {
      if (!Platform.isLinux) return;
      final app = await fakeBundle('${tmp.path}/apps/arca', 'old');
      final archive = await fakeArchive(tmp.path, 'new');
      expect(await installKindFor((os: 'linux', arch: 'x64'), app), InstallKind.restart);
      expect(await installKindFor((os: 'android', arch: 'arm64'), app), InstallKind.apk);
      expect(await installKindFor((os: 'linux', arch: 'x64'), Directory(tmp.path)), InstallKind.folder);
      final staged = await stageArchive(archive, 'linux', app);
      expect(staged.path, '${tmp.path}/apps/.arca-update/arca');
      expect(File('${staged.path}/version').readAsStringSync(), 'new');
      // Something that is not an Arca bundle is not staged.
      final other = File('${tmp.path}/other.tar.gz');
      Directory('${tmp.path}/x/stuff').createSync(recursive: true);
      await Process.run('tar', ['-czf', other.path, '-C', '${tmp.path}/x', 'stuff']);
      await expectLater(stageArchive(other, 'linux', app), throwsA(isA<ReleaseException>()));
      expect(Directory('${tmp.path}/apps/.arca-update').existsSync(), isFalse);
    });

    test('the swap script replaces the app, keeps the old one, and starts it', () async {
      if (!Platform.isLinux) return;
      final app = await fakeBundle('${tmp.path}/apps/arca', 'old');
      final archive = await fakeArchive(tmp.path, 'new');
      final staged = await stageArchive(archive, 'linux', app);
      final script = File('${tmp.path}/arca-update.sh')..writeAsStringSync(unixSwapScript);
      final log = '${tmp.path}/update.log';
      // Arca is still running while the script starts: it waits.
      final running = await Process.start('sleep', ['1']);
      final swap = await Process.start('/bin/sh', [script.path, '${running.pid}', app.path, staged.path, log]);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(File('${app.path}/version').readAsStringSync(), 'old');
      await running.exitCode;
      expect(await swap.exitCode, 0);
      expect(File('${app.path}/version').readAsStringSync(), 'new');
      expect(File('${app.path}.previous/version').readAsStringSync(), 'old');
      expect(Directory('${tmp.path}/apps/.arca-update').existsSync(), isFalse);
      // The new version was started, from its own folder.
      expect(File('${app.path}/started').readAsStringSync().trim(), 'new ${app.path}');
      expect(File(log).readAsStringSync(), contains('updated ${app.path}'));

      // Nothing staged: nothing changes, and the app starts again.
      File('${app.path}/started').deleteSync();
      final again = await Process.start('/bin/sh', [script.path, '999999', app.path, '${tmp.path}/none/arca', log]);
      expect(await again.exitCode, 0);
      expect(File('${app.path}/version').readAsStringSync(), 'new');
      expect(File('${app.path}.previous/version').readAsStringSync(), 'old');
      expect(File('${app.path}/started').existsSync(), isTrue);
      expect(File(log).readAsStringSync(), contains('nothing staged'));
    });
  });
}

/// A folder that looks like Arca's Linux bundle: `arca` (a script that
/// notes which version started, and where) and `lib/libapp.so`.
Future<Directory> fakeBundle(String path, String version) async {
  final dir = Directory(path);
  await Directory('$path/lib').create(recursive: true);
  File('$path/lib/libapp.so').writeAsStringSync('');
  File('$path/version').writeAsStringSync(version);
  File('$path/arca').writeAsStringSync('#!/bin/sh\necho "\$(cat version) \$(pwd)" > started\n');
  await Process.run('chmod', ['+x', '$path/arca']);
  return dir;
}

/// arca-linux-x64.tar.gz of a fake bundle of [version], with some bytes
/// that do not compress, so it spans several chunks over the network.
Future<File> fakeArchive(String tmp, String version, {int noise = 0}) async {
  final root = '$tmp/pack-$version';
  final bundle = await fakeBundle('$root/arca', version);
  if (noise > 0) {
    final rng = Random(5);
    File('${bundle.path}/lib/noise.bin').writeAsBytesSync(List.generate(noise, (_) => rng.nextInt(256)));
  }
  final out = File('$tmp/arca-linux-x64-$version.tar.gz');
  final r = await Process.run('tar', ['-czf', out.path, '-C', root, 'arca']);
  if (r.exitCode != 0) throw StateError('tar: ${r.stderr}');
  return out;
}
