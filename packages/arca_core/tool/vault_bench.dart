// Time one vault seal and open at the default Argon2id cost.
import 'dart:typed_data';

import 'package:arca_core/src/profiles/vault.dart';

Future<void> main() async {
  final s = ProfileSecrets(secretKey: Uint8List(32)..[0] = 1, i2pEncSeed: Uint8List(32), i2pSignSeed: Uint8List(32));
  final device = List.filled(32, 3);
  final sw = Stopwatch()..start();
  final sealed = await sealVault(s, deviceSecret: device);
  print('seal: ${sw.elapsedMilliseconds} ms');
  sw.reset();
  await openVault(sealed, deviceSecret: device);
  print('open: ${sw.elapsedMilliseconds} ms');
}
