// Time BIP-340 signing and verification.
import 'package:arca_core/src/crypto/schnorr.dart';

void main() {
  final sk = generateSecretKey();
  final pk = publicKeyOf(sk);
  final msg = generateSecretKey();
  final sw = Stopwatch()..start();
  late List<int> sig;
  for (var i = 0; i < 20; i++) {
    sig = schnorrSign(sk, msg);
  }
  print('sign: ${(sw.elapsedMicroseconds / 20 / 1000).toStringAsFixed(1)} ms');
  sw.reset();
  for (var i = 0; i < 20; i++) {
    schnorrVerify(pk, msg, sig);
  }
  print('verify: ${(sw.elapsedMicroseconds / 20 / 1000).toStringAsFixed(1)} ms');
}
