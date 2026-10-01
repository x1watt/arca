// Release announcements (docs/architecture.md, 11): a new version of Arca
// is announced as an addressable Nostr event signed by the release key,
// naming each download with its size and SHA-256. The SHA-256 is also the
// file's address in Arca's file service (5.7), so the files travel over
// I2P from whoever holds them and are checked by their hash, whoever
// served them.

import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

import '../crypto/hex.dart';
import '../nostr/event.dart';

/// This version of Arca. It mirrors `version:` in app/pubspec.yaml, which
/// is the source: a test fails when the two differ, and the release
/// workflow refuses a tag that does not match the pubspec.
const arcaVersion = '0.1.1+2';

/// The public key (BIP-340, hex) that signs releases. Its secret is kept
/// off line by the maintainer and in the release workflow's secrets.
/// npub1nx3aj0y25edc4y3ll98z6dgkqe02a8waj5x5ar505x4mh598zfcq57dzws
const trustedReleaseKey = '99a3d93c8aa65b8a923ff94e2d3516065eae9ddd950d4e8e8fa1abbbd0a71270';

/// The channel of this build; one announcement per channel.
const releaseChannel = 'stable';

String releaseDTag(String channel) => 'arca/release/$channel';

/// The repository whose GitHub releases carry the same files, for the
/// explicit HTTPS fallback.
const releaseRepository = 'x1watt/arca';

/// The longest release notes an announcement may carry, so the event and
/// its answer stay inside one I2P message.
const maxReleaseNotes = 6000;

class ReleaseException implements Exception {
  ReleaseException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// A version as `major.minor.patch`, with the build number after `+`.
class AppVersion implements Comparable<AppVersion> {
  const AppVersion(this.major, this.minor, this.patch, [this.build = 0]);

  final int major, minor, patch, build;

  static final _pattern = RegExp(r'^(\d{1,6})\.(\d{1,6})\.(\d{1,6})(?:\+(\d{1,9}))?$');

  /// Parses `1.2.3` or `1.2.3+45`; throws [FormatException] otherwise.
  factory AppVersion.parse(String text) {
    final m = _pattern.firstMatch(text.trim());
    if (m == null) throw FormatException('not a version: $text');
    return AppVersion(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!), int.parse(m[4] ?? '0'));
  }

  static AppVersion? tryParse(String text) {
    try {
      return AppVersion.parse(text);
    } on FormatException {
      return null;
    }
  }

  static final current = AppVersion.parse(arcaVersion);

  /// The version without the build number, as tags and the UI show it.
  String get name => '$major.$minor.$patch';

  @override
  int compareTo(AppVersion o) {
    for (final (a, b) in [(major, o.major), (minor, o.minor), (patch, o.patch), (build, o.build)]) {
      if (a != b) return a.compareTo(b);
    }
    return 0;
  }

  bool operator >(AppVersion other) => compareTo(other) > 0;
  bool operator <(AppVersion other) => compareTo(other) < 0;

  @override
  bool operator ==(Object other) => other is AppVersion && compareTo(other) == 0;

  @override
  int get hashCode => Object.hash(major, minor, patch, build);

  @override
  String toString() => '$name+$build';
}

/// What a download is for: an operating system and a processor.
typedef Target = ({String os, String arch});

/// The download names, fixed by the release workflow, and what each is
/// for.
const releaseAssetNames = <String, Target>{
  'arca-windows-x64.zip': (os: 'windows', arch: 'x64'),
  'arca-linux-x64.tar.gz': (os: 'linux', arch: 'x64'),
  'arca-android-arm64.apk': (os: 'android', arch: 'arm64'),
  'arca-android-armv7.apk': (os: 'android', arch: 'arm'),
  'arca-android-x86_64.apk': (os: 'android', arch: 'x64'),
};

/// The download this device needs, from the platform and the processor
/// the code runs on; null where Arca has none.
Target? currentTarget() {
  final abi = Abi.current();
  return switch (abi) {
    Abi.linuxX64 => (os: 'linux', arch: 'x64'),
    Abi.windowsX64 => (os: 'windows', arch: 'x64'),
    Abi.androidArm64 => (os: 'android', arch: 'arm64'),
    Abi.androidArm => (os: 'android', arch: 'arm'),
    Abi.androidX64 => (os: 'android', arch: 'x64'),
    _ => null,
  };
}

class ReleaseAsset {
  const ReleaseAsset({required this.name, required this.os, required this.arch, required this.size, required this.sha256});

  final String name, os, arch, sha256;
  final int size;

  /// Its address in Arca's file service (NIP-73 style, as files are named
  /// in comments and likes).
  String get content => 'arca:sha256:$sha256';

  Map<String, Object> toJson() => {
    'name': name,
    'os': os,
    'arch': arch,
    'size': size,
    'sha256': sha256,
    'content': content,
  };

  static final _safeName = RegExp(r'^arca-[a-z0-9_]+(?:-[a-z0-9_]+)*\.(?:zip|tar\.gz|apk)$');

  factory ReleaseAsset.fromJson(Map m) {
    final name = m['name'], os = m['os'], arch = m['arch'], size = m['size'], sha = m['sha256'];
    if (name is! String || !_safeName.hasMatch(name)) throw ReleaseException('bad file name: $name');
    if (os is! String || arch is! String) throw ReleaseException('$name: no platform');
    final known = releaseAssetNames[name];
    if (known != null && (known.os != os || known.arch != arch)) {
      throw ReleaseException('$name: named for ${known.os}/${known.arch}, announced for $os/$arch');
    }
    if (size is! int || size <= 0 || size > 4 << 30) throw ReleaseException('$name: bad size');
    if (sha is! String || !isHex(sha, 32)) throw ReleaseException('$name: bad SHA-256');
    if (m['content'] != null && m['content'] != 'arca:sha256:$sha') throw ReleaseException('$name: bad content address');
    return ReleaseAsset(name: name, os: os, arch: arch, size: size, sha256: sha);
  }
}

/// A release announcement whose signature and contents were checked.
class Release {
  Release._(this.event, this.version, this.date, this.notes, this.tag, this.assets);

  final NostrEvent event;
  final AppVersion version;
  final String date, notes, tag;
  final List<ReleaseAsset> assets;

  ReleaseAsset? assetFor(Target? t) =>
      t == null ? null : assets.where((a) => a.os == t.os && a.arch == t.arch).firstOrNull;

  ReleaseAsset? assetBySha(String sha) => assets.where((a) => a.sha256 == sha).firstOrNull;

  /// Where the same file is on GitHub, for the explicit HTTPS fallback.
  Uri githubUrl(ReleaseAsset a) => Uri.https('github.com', '/$releaseRepository/releases/download/$tag/${a.name}');

  /// Newer than [o]: a higher version, or the same one announced later.
  bool newerThan(Release? o) {
    if (o == null) return true;
    final c = version.compareTo(o.version);
    return c > 0 || (c == 0 && event.createdAt > o.event.createdAt);
  }

  /// Checks [e]: a signature by [key], the release kind and channel, and
  /// contents that parse. Throws [ReleaseException] with the reason.
  factory Release.verify(NostrEvent e, {String key = trustedReleaseKey, String channel = releaseChannel}) {
    if (e.kind != Kind.arcaRelease) throw ReleaseException('not a release announcement (kind ${e.kind})');
    if (e.pubkey != key) throw ReleaseException('not signed by the release key');
    if (e.dTag != releaseDTag(channel)) throw ReleaseException('for another channel (${e.dTag})');
    if (!e.verify()) throw ReleaseException('bad signature');
    final Object? json;
    try {
      json = jsonDecode(e.content);
    } on FormatException {
      throw ReleaseException('unreadable contents');
    }
    if (json is! Map) throw ReleaseException('unreadable contents');
    final version = AppVersion.tryParse('${json['version']}+${json['build']}');
    if (version == null) throw ReleaseException('bad version');
    if (e.tagValues('version').firstOrNull != version.name) throw ReleaseException('version tag does not match');
    final assets = [for (final a in json['assets'] as List? ?? const []) ReleaseAsset.fromJson(a as Map)];
    if (assets.isEmpty) throw ReleaseException('no files');
    if (assets.map((a) => a.name).toSet().length != assets.length) throw ReleaseException('a file is named twice');
    final notes = json['notes'] as String? ?? '';
    if (notes.length > maxReleaseNotes) throw ReleaseException('notes too long');
    final tag = json['tag'] as String? ?? 'v${version.name}';
    if (tag != 'v${version.name}') throw ReleaseException('tag $tag does not match version ${version.name}');
    return Release._(e, version, json['date'] as String? ?? '', notes, tag, assets);
  }

  static Release? tryVerify(NostrEvent e, {String key = trustedReleaseKey}) {
    try {
      return Release.verify(e, key: key);
    } on ReleaseException {
      return null;
    }
  }
}

/// Signs a release announcement with [secretKey] (the release workflow's
/// tool/sign_release.dart, and tests).
NostrEvent signRelease({
  required List<int> secretKey,
  required AppVersion version,
  required List<ReleaseAsset> assets,
  String notes = '',
  String? date,
  String channel = releaseChannel,
  int? createdAt,
}) {
  final day = date ?? DateTime.now().toUtc().toIso8601String().substring(0, 10);
  final trimmed = notes.length > maxReleaseNotes ? '${notes.substring(0, maxReleaseNotes - 3)}...' : notes;
  return NostrEvent.sign(
    secretKey: secretKey,
    kind: Kind.arcaRelease,
    createdAt: createdAt,
    content: jsonEncode({
      'version': version.name,
      'build': version.build,
      'date': day,
      'tag': 'v${version.name}',
      'notes': trimmed,
      'assets': [for (final a in assets) a.toJson()],
    }),
    tags: [
      ['d', releaseDTag(channel)],
      ['version', version.name],
      ['alt', 'Arca ${version.name} release'],
      for (final a in assets) ['x', a.sha256],
    ],
  );
}

/// The section of CHANGELOG.md for [version] (`## 0.1.1 ...` up to the
/// next `## `), without its heading; empty when there is none.
String changelogSection(String changelog, String version) {
  final lines = const LineSplitter().convert(changelog);
  final start = lines.indexWhere((l) => RegExp('^## \\[?${RegExp.escape(version)}\\]?(\\s|\$)').hasMatch(l));
  if (start < 0) return '';
  final out = <String>[];
  for (final l in lines.skip(start + 1)) {
    if (l.startsWith('## ')) break;
    out.add(l);
  }
  return out.join('\n').trim();
}

/// Whether [dir] can be written to (creating and removing a file in it).
Future<bool> dirWritable(Directory dir) async {
  final probe = File('${dir.path}/.arca-write-test-$pid');
  try {
    await probe.writeAsString('');
    await probe.delete();
    return true;
  } on FileSystemException {
    return false;
  }
}
