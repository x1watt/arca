import 'dart:io';
import 'dart:typed_data';

import 'package:arca_core/src/crypto/hex.dart';
import 'package:arca_core/src/crypto/schnorr.dart';
import 'package:arca_core/src/nostr/nip19.dart';
import 'package:arca_core/src/profiles/profile_store.dart';
import 'package:arca_core/src/profiles/vault.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('arca_profiles'));
  tearDown(() async => dir.delete(recursive: true));

  group('vault', () {
    final secrets = ProfileSecrets(
      secretKey: generateSecretKey(),
      i2pEncSeed: Uint8List.fromList(List.filled(32, 1)),
      i2pSignSeed: Uint8List.fromList(List.filled(32, 2)),
    );
    final device = List.filled(32, 7);

    test('opens with the right device key and passphrase only', () async {
      final sealed = await sealVault(secrets, deviceSecret: device, passphrase: 'pw', cost: VaultCost.test);
      final back = await openVault(sealed, deviceSecret: device, passphrase: 'pw');
      expect(back.secretKey, secrets.secretKey);
      expect(back.i2pSignSeed, secrets.i2pSignSeed);
      expect(() => openVault(sealed, deviceSecret: device, passphrase: 'nope'), throwsA(isA<VaultException>()));
      expect(
        () => openVault(sealed, deviceSecret: List.filled(32, 8), passphrase: 'pw'),
        throwsA(isA<VaultException>()),
      );
    });

    test('detects a damaged file', () async {
      final sealed = await sealVault(secrets, deviceSecret: device, cost: VaultCost.test);
      final damaged = Uint8List.fromList(sealed)..[60] ^= 1;
      expect(() => openVault(damaged, deviceSecret: device), throwsA(isA<VaultException>()));
      expect(() => openVault(Uint8List(10), deviceSecret: device), throwsA(isA<VaultException>()));
    });

    test('the secret key never appears in the file', () async {
      final sealed = await sealVault(secrets, deviceSecret: device, cost: VaultCost.test);
      expect(String.fromCharCodes(sealed).contains(toHex(secrets.secretKey)), isFalse);
    });
  });

  group('profile store', () {
    test('first run creates one profile automatically, and it survives a restart', () async {
      var store = await ProfileStore.open(dir, cost: VaultCost.test);
      expect(store.profiles, isEmpty);
      final p = await store.ensureProfile();
      expect(p.name, startsWith('Arca user '));
      expect(p.stayOnline, isTrue);
      expect(await store.ensureProfile(), isA<ProfileInfo>());
      expect(store.profiles.length, 1);

      store = await ProfileStore.open(dir, cost: VaultCost.test);
      expect(store.active!.pubkey, p.pubkey);
      final secrets = await store.unlock(p.id);
      expect(toHex(publicKeyOf(secrets.secretKey)), p.pubkey);
      secrets.wipe();
      expect(secrets.secretKey.every((b) => b == 0), isTrue);
    });

    test('imports an nsec as a separate profile and refuses duplicates', () async {
      final store = await ProfileStore.open(dir, cost: VaultCost.test);
      final first = await store.ensureProfile();
      final sk = generateSecretKey();
      final imported = await store.importKey(nsecEncode(sk), name: 'Club station');
      expect(imported.pubkey, toHex(publicKeyOf(sk)));
      expect(imported.name, 'Club station');
      expect(imported.stayOnline, isFalse);
      expect(store.profiles.length, 2);
      expect(store.active!.id, first.id, reason: 'import does not switch by itself');
      await expectLater(store.importKey(nsecEncode(sk)), throwsA(isA<ProfileException>()));
      await expectLater(store.importKey(toHex(sk)), throwsA(isA<ProfileException>()));
    });

    test('explains bad input', () async {
      final store = await ProfileStore.open(dir, cost: VaultCost.test);
      Future<String> err(String s) async {
        try {
          await store.importKey(s);
          return '';
        } on ProfileException catch (e) {
          return e.message;
        }
      }

      expect(await err('hello'), contains('Not a Nostr secret key'));
      final nsec = nsecEncode(generateSecretKey());
      expect(await err('${nsec.substring(0, nsec.length - 1)}x'), contains('checksum'));
      expect(await err(npubEncode(publicKeyOf(generateSecretKey()))), contains('Not a Nostr secret key'));
    });

    test('switches, renames, and deletes profiles', () async {
      final store = await ProfileStore.open(dir, cost: VaultCost.test);
      final a = await store.create(name: 'A');
      final b = await store.create(name: 'B');
      await store.setActive(b.id);
      expect(store.active!.id, b.id);
      await store.rename(b.id, 'Bee');
      await store.setStayOnline(b.id, true);
      final reopened = await ProfileStore.open(dir, cost: VaultCost.test);
      expect(reopened.active!.name, 'Bee');
      expect(reopened.active!.stayOnline, isTrue);
      await reopened.delete(b.id);
      expect(reopened.active!.id, a.id);
      expect(await reopened.profileDir(b.id).exists(), isFalse);
    });

    test('secrets are readable only by their owner', () async {
      final store = await ProfileStore.open(dir, cost: VaultCost.test);
      final p = await store.create();
      String mode(String path) => (FileStat.statSync(path).mode & 0x1ff).toRadixString(8);
      expect(mode('${dir.path}/device.key'), '600');
      expect(mode('${store.profileDir(p.id).path}/vault.bin'), '600');
      expect(mode(store.profileDir(p.id).path), '700');
    }, testOn: 'linux || mac-os');

    test('folder names do not reveal the key', () async {
      final store = await ProfileStore.open(dir, cost: VaultCost.test);
      final p = await store.create();
      expect(store.profileDir(p.id).path.contains(p.pubkey), isFalse);
      expect(p.npubShort, matches(RegExp(r'^npub1[a-z0-9]{8}\.\.\.[a-z0-9]{5}$')));
    });
  });
}
