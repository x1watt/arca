// Signs the release announcement in the release workflow
// (.github/workflows/release.yml; docs/architecture.md, 11): version and
// build from app/pubspec.yaml, notes from CHANGELOG.md, and for each
// download in <dist> its size and SHA-256. The secret release key comes
// from the environment (ARCA_RELEASE_NSEC), never from a file in the
// repository. Writes the signed event as JSON.
//
//   dart run tool/sign_release.dart --dist=<dir> --tag=v0.1.1 \
//     [--pubspec=../../app/pubspec.yaml] [--changelog=../../CHANGELOG.md] \
//     [--out=<dist>/release.json] [--notes-out=<file>]
//
// --notes-out also writes the notes alone, for the GitHub release page.
//
// It refuses a tag that does not match the pubspec, a pubspec that does
// not match the version built into the core (arcaVersion), a missing
// download, and a key that is not the one the app trusts.
import 'dart:convert';
import 'dart:io';

import 'package:arca_core/arca_core.dart';

Never fail(String m) {
  stderr.writeln('sign_release: $m');
  exit(1);
}

Future<void> main(List<String> args) async {
  final o = {
    for (final a in args.where((a) => a.startsWith('--') && a.contains('=')))
      a.substring(2, a.indexOf('=')): a.substring(a.indexOf('=') + 1),
  };
  final dist = o['dist'] ?? fail('--dist=<folder with the downloads> is needed');
  final tag = o['tag'] ?? fail('--tag=v<version> is needed');
  final pubspec = File(o['pubspec'] ?? '../../app/pubspec.yaml');
  final changelog = File(o['changelog'] ?? '../../CHANGELOG.md');
  final out = File(o['out'] ?? '$dist/release.json');
  final notesOut = o['notes-out'];

  final line = (await pubspec.readAsLines()).firstWhere((l) => l.startsWith('version:'), orElse: () => '');
  final version = AppVersion.tryParse(line.replaceFirst('version:', '').trim()) ??
      fail('no version in ${pubspec.path}');
  if (tag != 'v${version.name}') fail('tag $tag does not match the pubspec version ${version.name}');
  if (AppVersion.parse(arcaVersion) != version) {
    fail('arcaVersion ($arcaVersion, lib/src/update/release.dart) differs from the pubspec ($version)');
  }

  final nsec = (Platform.environment['ARCA_RELEASE_NSEC'] ?? '').trim();
  if (nsec.isEmpty) fail('ARCA_RELEASE_NSEC is not set');
  final secret = decodeEntity(nsec, 'nsec');
  if (toHex(publicKeyOf(secret)) != trustedReleaseKey) fail('ARCA_RELEASE_NSEC is not the release key the app trusts');

  final assets = <ReleaseAsset>[];
  for (final MapEntry(key: name, value: target) in releaseAssetNames.entries) {
    final f = File('$dist/$name');
    if (!await f.exists()) fail('$name is missing from $dist');
    final (sha, _, size) = await hashFile(f);
    assets.add(ReleaseAsset(name: name, os: target.os, arch: target.arch, size: size, sha256: sha));
    print('$sha  $size  $name');
  }
  final notes = await changelog.exists() ? changelogSection(await changelog.readAsString(), version.name) : '';
  if (notes.isEmpty) stderr.writeln('sign_release: no notes for ${version.name} in ${changelog.path}');

  final event = signRelease(secretKey: secret, version: version, assets: assets, notes: notes);
  secret.fillRange(0, secret.length, 0);
  final release = Release.verify(event);
  await out.writeAsString('${const JsonEncoder.withIndent('  ').convert(event.toJson())}\n');
  if (notesOut != null) await File(notesOut).writeAsString('${release.notes}\n');
  print('signed ${release.version} as event ${event.id} by $trustedReleaseKey: ${out.path}');
}
