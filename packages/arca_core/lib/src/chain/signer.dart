// Who signs for an account. The chain runs in its own isolate while the
// profiles' secret keys stay in the core isolate (docs/architecture.md,
// 3.5 and 7), so the chain signs through a [Signer]: in the app one that
// asks the core for each signature, in tests and tools one that holds the
// key.

import 'dart:typed_data';

import '../crypto/hex.dart';
import '../crypto/schnorr.dart';

abstract class Signer {
  /// The account (x-only public key, hex).
  String get publicKey;

  /// A BIP-340 signature over [message].
  Future<Uint8List> sign(Uint8List message);
}

class LocalSigner implements Signer {
  LocalSigner(List<int> secretKey) : _secret = Uint8List.fromList(secretKey), publicKey = toHex(publicKeyOf(secretKey));

  final Uint8List _secret;

  @override
  final String publicKey;

  @override
  Future<Uint8List> sign(Uint8List message) async => schnorrSign(_secret, message);
}
