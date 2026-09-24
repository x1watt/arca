// BIP-340 against vectors produced by the published bip340 package (the
// first two are the official BIP-340 test vectors 0 and 1).
import 'dart:convert';
import 'dart:io';

import 'package:arca_core/src/crypto/hex.dart';
import 'package:arca_core/src/crypto/schnorr.dart';
import 'package:test/test.dart';

void main() {
  final vectors = (jsonDecode(File('test/fixtures/bip340_vectors.json').readAsStringSync()) as List)
      .cast<Map<String, dynamic>>();

  test('public keys match', () {
    for (final v in vectors) {
      expect(toHex(publicKeyOf(fromHex(v['sk']))), v['pk']);
    }
  });

  test('signatures match byte for byte and verify', () {
    for (final v in vectors) {
      final sig = schnorrSign(fromHex(v['sk']), fromHex(v['msg']), aux: fromHex(v['aux']));
      expect(toHex(sig), v['sig']);
      expect(schnorrVerify(fromHex(v['pk']), fromHex(v['msg']), sig), isTrue);
    }
  });

  test('rejects a changed message, key or signature', () {
    final v = vectors[5];
    final pk = fromHex(v['pk']), msg = fromHex(v['msg']), sig = fromHex(v['sig']);
    expect(schnorrVerify(pk, msg, sig), isTrue);
    expect(schnorrVerify(pk, [...msg]..[0] ^= 1, sig), isFalse);
    expect(schnorrVerify(fromHex(vectors[6]['pk']), msg, sig), isFalse);
    expect(schnorrVerify(pk, msg, [...sig]..[40] ^= 1), isFalse);
    expect(schnorrVerify(pk, msg, sig.sublist(0, 63)), isFalse);
  });

  test('random keys sign and verify', () {
    for (var i = 0; i < 5; i++) {
      final sk = generateSecretKey();
      final msg = generateSecretKey();
      expect(schnorrVerify(publicKeyOf(sk), msg, schnorrSign(sk, msg)), isTrue);
    }
  });

  test('invalid secret keys are refused', () {
    expect(isValidSecretKey(List.filled(32, 0)), isFalse);
    expect(isValidSecretKey(List.filled(31, 1)), isFalse);
    expect(() => publicKeyOf(List.filled(32, 0xff)), throwsA(isA<SchnorrException>()));
  });
}
