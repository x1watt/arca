// Makes the release key: a BIP-340 (Nostr) key pair that signs release
// announcements (docs/architecture.md, 11). The secret goes to a file
// readable only by its owner; the public key is printed, to be built into
// the app as `trustedReleaseKey` (lib/src/update/release.dart).
//
//   dart run tool/release_key.dart <file for the nsec>
//
// It refuses to overwrite an existing file: a new release key is a new
// trust root, and every installed copy of Arca would stop accepting
// updates signed with it.
import 'dart:io';

import 'package:arca_core/arca_core.dart';

Future<void> main(List<String> args) async {
  if (args.length != 1) {
    stderr.writeln('usage: release_key.dart <file for the nsec>');
    exit(64);
  }
  final out = File(args.single);
  if (out.existsSync()) {
    stderr.writeln('${out.path} exists already; not overwriting a release key.');
    exit(1);
  }
  final secret = generateSecretKey();
  final pub = publicKeyOf(secret);
  await out.parent.create(recursive: true);
  await out.writeAsString('${nsecEncode(secret)}\n', flush: true);
  if (!Platform.isWindows) await Process.run('chmod', ['600', out.path]);
  secret.fillRange(0, secret.length, 0);
  print('secret key written to ${out.path}');
  print('public key (hex):  ${toHex(pub)}');
  print('public key (npub): ${npubEncode(pub)}');
}
