// Profiles on this device (docs/architecture.md, 3 and 6): each one is a
// separate account with its own Nostr key, I2P destination seeds and data
// folder. The store keeps public details in device.json and secrets in each
// profile's encrypted vault.

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../crypto/hex.dart';
import '../crypto/schnorr.dart';
import '../nostr/nip19.dart';
import 'vault.dart';

class ProfileInfo {
  const ProfileInfo({
    required this.id,
    required this.name,
    required this.pubkey,
    required this.createdAt,
    this.stayOnline = false,
  });

  /// Random local id; also the folder name, so folders do not reveal the key.
  final String id;
  final String name;

  /// Nostr public key, lowercase hex.
  final String pubkey;
  final int createdAt;
  final bool stayOnline;

  String get npub => npubEncode(fromHex(pubkey));

  /// Short form for display, such as npub1a7f3kq9...w91c2.
  String get npubShort {
    final n = npub;
    return '${n.substring(0, 13)}...${n.substring(n.length - 5)}';
  }

  ProfileInfo copyWith({String? name, bool? stayOnline}) => ProfileInfo(
    id: id,
    name: name ?? this.name,
    pubkey: pubkey,
    createdAt: createdAt,
    stayOnline: stayOnline ?? this.stayOnline,
  );

  Map<String, Object> toJson() => {
    'id': id,
    'name': name,
    'pubkey': pubkey,
    'createdAt': createdAt,
    'stayOnline': stayOnline,
  };

  factory ProfileInfo.fromJson(Map<String, dynamic> m) => ProfileInfo(
    id: m['id'] as String,
    name: m['name'] as String,
    pubkey: m['pubkey'] as String,
    createdAt: m['createdAt'] as int,
    stayOnline: m['stayOnline'] as bool? ?? false,
  );
}

class ProfileException implements Exception {
  ProfileException(this.message);
  final String message;
  @override
  String toString() => message;
}

class ProfileStore {
  ProfileStore._(this.dir, this._deviceSecret, this._cost, this.deviceId, this._profiles, this._active);

  final Directory dir;
  final Uint8List _deviceSecret;
  final VaultCost _cost;
  final String deviceId;
  final List<ProfileInfo> _profiles;
  String? _active;

  /// Opens (or creates) the device data under [dir].
  static Future<ProfileStore> open(Directory dir, {VaultCost cost = const VaultCost()}) async {
    await dir.create(recursive: true);
    final secret = await _deviceKey(File('${dir.path}/device.key'));
    final devFile = File('${dir.path}/device.json');
    var deviceId = _randomHex(8);
    final profiles = <ProfileInfo>[];
    String? active;
    if (await devFile.exists()) {
      final m = jsonDecode(await devFile.readAsString()) as Map<String, dynamic>;
      deviceId = m['deviceId'] as String;
      profiles.addAll([for (final p in m['profiles'] as List) ProfileInfo.fromJson(p as Map<String, dynamic>)]);
      active = m['active'] as String?;
    }
    final store = ProfileStore._(dir, secret, cost, deviceId, profiles, active);
    if (!await devFile.exists()) await store._save();
    return store;
  }

  List<ProfileInfo> get profiles => List.unmodifiable(_profiles);

  ProfileInfo? get active => _profiles.where((p) => p.id == _active).firstOrNull ?? _profiles.firstOrNull;

  Directory profileDir(String id) => Directory('${dir.path}/profiles/$id');

  /// On first run, creates a profile without asking anything
  /// (docs/architecture.md, 3.2). Returns the active profile.
  Future<ProfileInfo> ensureProfile() async => active ?? await create();

  /// Creates a new profile with a fresh key.
  Future<ProfileInfo> create({String? name}) => _add(generateSecretKey(), name);

  /// Imports an existing Nostr key as a new profile. Accepts an nsec or 64
  /// hex characters. Existing profiles are left as they are.
  Future<ProfileInfo> importKey(String input, {String? name}) {
    final text = input.trim();
    final Uint8List secret;
    try {
      if (text.toLowerCase().startsWith('nsec1')) {
        secret = decodeEntity(text, 'nsec');
      } else if (text.toLowerCase().startsWith('ncryptsec1')) {
        throw ProfileException('ncryptsec import is not supported yet; paste the nsec instead');
      } else if (isHex(text, 32)) {
        secret = fromHex(text.toLowerCase());
      } else {
        throw ProfileException('Not a Nostr secret key. Paste an nsec1... key.');
      }
    } on FormatException {
      throw ProfileException('That key is damaged or mistyped (checksum failed).');
    }
    if (!isValidSecretKey(secret)) throw ProfileException('That key is not a valid secret key.');
    return _add(secret, name);
  }

  Future<ProfileInfo> _add(Uint8List secret, String? name) async {
    final pubkey = toHex(publicKeyOf(secret));
    if (_profiles.any((p) => p.pubkey == pubkey)) {
      throw ProfileException('This account is already on this device.');
    }
    final rng = Random.secure();
    Uint8List seed() => Uint8List.fromList(List.generate(32, (_) => rng.nextInt(256)));
    final secrets = ProfileSecrets(secretKey: secret, i2pEncSeed: seed(), i2pSignSeed: seed());
    final id = _randomHex(8);
    final pdir = profileDir(id);
    await pdir.create(recursive: true);
    await _writeAtomic(
      File('${pdir.path}/vault.bin'),
      await sealVault(secrets, deviceSecret: _deviceSecret, cost: _cost),
    );
    await _ownerOnly(pdir.path);
    await _ownerOnly('${pdir.path}/vault.bin');
    secrets.wipe();
    final npub = npubEncode(fromHex(pubkey));
    final info = ProfileInfo(
      id: id,
      name: name?.trim().isNotEmpty == true ? name!.trim() : 'Arca user ${npub.substring(5, 9)}',
      pubkey: pubkey,
      createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      stayOnline: _profiles.isEmpty,
    );
    _profiles.add(info);
    _active ??= id;
    await _save();
    return info;
  }

  /// Decrypts a profile's secrets. The caller must [ProfileSecrets.wipe]
  /// them when done.
  Future<ProfileSecrets> unlock(String id) async {
    final f = File('${profileDir(id).path}/vault.bin');
    if (!await f.exists()) throw ProfileException('Profile $id has no vault');
    return openVault(await f.readAsBytes(), deviceSecret: _deviceSecret);
  }

  Future<void> setActive(String id) async {
    _require(id);
    _active = id;
    await _save();
  }

  Future<ProfileInfo> rename(String id, String name) => _update(id, (p) => p.copyWith(name: name.trim()));

  Future<ProfileInfo> setStayOnline(String id, bool on) => _update(id, (p) => p.copyWith(stayOnline: on));

  /// Deletes a profile's vault and data. Shared device data stays.
  Future<void> delete(String id) async {
    _require(id);
    final d = profileDir(id);
    if (await d.exists()) await d.delete(recursive: true);
    _profiles.removeWhere((p) => p.id == id);
    if (_active == id) _active = _profiles.firstOrNull?.id;
    await _save();
  }

  Future<ProfileInfo> _update(String id, ProfileInfo Function(ProfileInfo) f) async {
    final i = _profiles.indexWhere((p) => p.id == id);
    if (i < 0) throw ProfileException('No profile $id');
    _profiles[i] = f(_profiles[i]);
    await _save();
    return _profiles[i];
  }

  void _require(String id) {
    if (!_profiles.any((p) => p.id == id)) throw ProfileException('No profile $id');
  }

  Future<void> _save() => _writeAtomic(
    File('${dir.path}/device.json'),
    utf8.encode(
      const JsonEncoder.withIndent('  ').convert({
        'deviceId': deviceId,
        'active': _active,
        'profiles': [for (final p in _profiles) p.toJson()],
      }),
    ),
  );

  /// The device secret that, with Argon2id, protects every vault. It lives in
  /// a file readable only by the user until platform keystores are wired in.
  static Future<Uint8List> _deviceKey(File f) async {
    if (await f.exists()) {
      final b = await f.readAsBytes();
      if (b.length == 32) return b;
      throw ProfileException('device.key is damaged');
    }
    final rng = Random.secure();
    final key = Uint8List.fromList(List.generate(32, (_) => rng.nextInt(256)));
    await _writeAtomic(f, key);
    await _ownerOnly(f.path);
    await _ownerOnly(f.parent.path);
    return key;
  }

  /// Restricts a file or folder to its owner (Linux and macOS).
  static Future<void> _ownerOnly(String path) async {
    if (!Platform.isLinux && !Platform.isMacOS) return;
    final isDir = await FileSystemEntity.isDirectory(path);
    await Process.run('chmod', [isDir ? '700' : '600', path]);
  }

  static Future<void> _writeAtomic(File f, List<int> bytes) async {
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(f.path);
  }

  static String _randomHex(int n) {
    final rng = Random.secure();
    return toHex(List.generate(n, (_) => rng.nextInt(256)));
  }
}
