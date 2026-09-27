// Schnorr signatures by any point, not only x-only keys (BIP-340): the
// chain's private money signs with kernel excesses and one-time output
// keys, which may have either parity of y. Signature: (R, s) with
// s*G = R + e*P and e = H(R, P, message).

import 'dart:typed_data';

import 'curve.dart';

BigInt _challenge(Point r, Point p, List<int> message) => hashToScalar('arca/sig', [r, p, message]);

/// 65 bytes: R (33) and s (32).
Uint8List pointSign(BigInt secret, List<int> message) {
  final d = secret % curveN;
  final p = Point.g * d;
  // A deterministic nonce from the key and message, mixed with randomness.
  final k = hashToScalar('arca/nonce', [d, message, randomScalar()]);
  final r = Point.g * k;
  final s = (k + _challenge(r, p, message) * d) % curveN;
  return Uint8List.fromList([...r.encoded, ...scalarBytes(s)]);
}

bool pointVerify(Point key, List<int> message, List<int> signature) {
  if (signature.length != 65 || key.isInfinity) return false;
  final r = Point.decode(signature.sublist(0, 33));
  if (r == null || r.isInfinity) return false;
  final s = scalarOf(signature.sublist(33));
  if (s >= curveN) return false;
  return Point.g * s == r + key * _challenge(r, key, message);
}
