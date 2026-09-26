// A profile's secrets at rest: its Nostr secret key and I2P destination
// seeds, encrypted with XChaCha20-Poly1305 under a key derived with Argon2id
// (docs/architecture.md, 3.5).

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../crypto/hex.dart';

/// Argon2id cost. The default follows current OWASP guidance; tests use a
/// cheap one.
class VaultCost {
  const VaultCost({this.memoryKiB = 19456, this.iterations = 2});
  final int memoryKiB;
  final int iterations;
  static const test = VaultCost(memoryKiB: 64, iterations: 1);
}

class ProfileSecrets {
  const ProfileSecrets({required this.secretKey, required this.i2pEncSeed, required this.i2pSignSeed});
  final Uint8List secretKey;
  final Uint8List i2pEncSeed;
  final Uint8List i2pSignSeed;

  /// Overwrites the key material in memory.
  void wipe() {
    secretKey.fillRange(0, secretKey.length, 0);
    i2pEncSeed.fillRange(0, i2pEncSeed.length, 0);
    i2pSignSeed.fillRange(0, i2pSignSeed.length, 0);
  }
}

class VaultException implements Exception {
  VaultException(this.message);
  final String message;
  @override
  String toString() => 'VaultException: $message';
}

const _magic = [0x41, 0x52, 0x43, 0x56]; // "ARCV"
const _version = 1;

Future<SecretKey> _deriveKey(List<int> deviceSecret, String? passphrase, List<int> salt, VaultCost cost) {
  final input = [...deviceSecret, if (passphrase != null) ...utf8.encode(passphrase)];
  return Argon2id(
    memory: cost.memoryKiB,
    parallelism: 1,
    iterations: cost.iterations,
    hashLength: 32,
  ).deriveKey(secretKey: SecretKey(input), nonce: salt);
}

/// Encrypts [secrets] for storage.
Future<Uint8List> sealVault(
  ProfileSecrets secrets, {
  required List<int> deviceSecret,
  String? passphrase,
  VaultCost cost = const VaultCost(),
}) async {
  final rng = Random.secure();
  final salt = List.generate(16, (_) => rng.nextInt(256));
  final key = await _deriveKey(deviceSecret, passphrase, salt, cost);
  final algo = Xchacha20.poly1305Aead();
  final nonce = algo.newNonce();
  final plain = utf8.encode(
    jsonEncode({
      'secret': toHex(secrets.secretKey),
      'i2pEnc': toHex(secrets.i2pEncSeed),
      'i2pSign': toHex(secrets.i2pSignSeed),
    }),
  );
  final box = await algo.encrypt(plain, secretKey: key, nonce: nonce);
  final header = BytesBuilder()
    ..add(_magic)
    ..addByte(_version)
    ..add(_u32(cost.memoryKiB))
    ..addByte(cost.iterations)
    ..add(salt);
  return (BytesBuilder()
        ..add(header.toBytes())
        ..add(box.nonce)
        ..add(box.cipherText)
        ..add(box.mac.bytes))
      .toBytes();
}

/// Decrypts a vault; throws [VaultException] for a wrong key or damaged file.
Future<ProfileSecrets> openVault(Uint8List data, {required List<int> deviceSecret, String? passphrase}) async {
  const headerLen = 4 + 1 + 4 + 1 + 16;
  if (data.length < headerLen + 24 + 16 || !_equal(data.sublist(0, 4), _magic) || data[4] != _version) {
    throw VaultException('not a vault file');
  }
  final cost = VaultCost(memoryKiB: _readU32(data, 5), iterations: data[9]);
  final salt = data.sublist(10, 26);
  final nonce = data.sublist(26, 50);
  final cipher = data.sublist(50, data.length - 16);
  final mac = Mac(data.sublist(data.length - 16));
  final key = await _deriveKey(deviceSecret, passphrase, salt, cost);
  final List<int> plain;
  try {
    plain = await Xchacha20.poly1305Aead().decrypt(
      SecretBox(cipher, nonce: nonce, mac: mac),
      secretKey: key,
    );
  } on SecretBoxAuthenticationError {
    throw VaultException('wrong key or damaged vault');
  }
  final m = jsonDecode(utf8.decode(plain)) as Map<String, dynamic>;
  return ProfileSecrets(
    secretKey: fromHex(m['secret'] as String),
    i2pEncSeed: fromHex(m['i2pEnc'] as String),
    i2pSignSeed: fromHex(m['i2pSign'] as String),
  );
}

List<int> _u32(int v) => [(v >> 24) & 0xff, (v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff];
int _readU32(List<int> b, int o) => (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];
bool _equal(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
