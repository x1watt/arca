import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:arca_core/arca_core.dart';
import 'package:arca_core/src/transport/blobs.dart';
import 'package:arca_core/src/transport/reading.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  setUp(() async => tmp = await Directory.systemTemp.createTemp('arca_blobs'));
  tearDown(() => tmp.delete(recursive: true));

  Future<(File, String)> randomFile(String name, int size) async {
    final f = File('${tmp.path}/$name');
    final rng = Random(name.hashCode ^ size);
    await f.writeAsBytes(Uint8List.fromList(List.generate(size, (_) => rng.nextInt(256))));
    final (sha, _, _) = await hashFile(f);
    return (f, sha);
  }

  BlobService serve(LoopbackNetwork net, String address, Map<String, String> files, {Duration? timeout}) => BlobService(
    address: address,
    link: net.link([address]),
    resolve: (sha) async => files[sha],
    chunkTimeout: timeout ?? const Duration(milliseconds: 300),
  );

  test('fetches a file in chunks, byte for byte, through message loss', () async {
    final net = LoopbackNetwork(dropRate: 0.1);
    final (src, sha) = await randomFile('src.bin', 1000 * 1000 + 17);
    serve(net, 'a', {sha: src.path});
    final b = serve(net, 'b', {});
    final out = '${tmp.path}/got/copy.bin';
    var progress = 0;
    final r = await b.fetch(sha, await src.length(), ['a'], out, onProgress: (n) => progress = n);
    expect(r.ok, isTrue, reason: r.error);
    expect(await File(out).readAsBytes(), await src.readAsBytes());
    expect(progress, await src.length());
    expect(File('$out.part').existsSync(), isFalse);
  });

  test('continues where it stopped when the provider comes back', () async {
    final net = LoopbackNetwork();
    final (src, sha) = await randomFile('big.bin', 600 * 1024);
    serve(net, 'a', {sha: src.path});
    final b = serve(net, 'b', {});
    final out = '${tmp.path}/copy.bin';
    var stop = false;
    final first = b.fetch(
      sha,
      await src.length(),
      ['a'],
      out,
      onProgress: (n) {
        if (n > 200 * 1024) stop = true;
      },
      cancelled: () => stop,
    );
    expect((await first).cancelled, isTrue);
    expect(File('$out.part').existsSync(), isTrue);
    final kept = File('$out.part.have').readAsBytesSync().where((h) => h == 1).length;
    expect(kept, greaterThan(0));
    // Goes offline, comes back; the second run only fetches what is missing.
    net.setOnline('a', false);
    net.setOnline('a', true);
    var fetchedAgain = 0;
    final start = kept * blobChunk;
    final r = await b.fetch(sha, await src.length(), ['a'], out, onProgress: (n) => fetchedAgain = n - start);
    expect(r.ok, isTrue, reason: r.error);
    expect(await File(out).readAsBytes(), await src.readAsBytes());
    expect(fetchedAgain, lessThan(await src.length()));
  });

  test('asks another provider when one does not have it, and fails when nobody does', () async {
    final net = LoopbackNetwork();
    final (src, sha) = await randomFile('x.bin', 100 * 1024);
    serve(net, 'empty', {});
    serve(net, 'full', {sha: src.path});
    final b = serve(net, 'b', {});
    final r = await b.fetch(sha, await src.length(), ['empty', 'full'], '${tmp.path}/x1.bin');
    expect(r.ok, isTrue, reason: r.error);
    final none = await b.fetch(sha, await src.length(), ['empty'], '${tmp.path}/x2.bin');
    expect(none.error, contains('Nobody'));
  });

  test('rejects bytes that do not match the fingerprint', () async {
    final net = LoopbackNetwork();
    final (src, _) = await randomFile('real.bin', 50 * 1024);
    final (_, otherSha) = await randomFile('other.bin', 50 * 1024);
    // A provider that serves the wrong bytes under the requested hash.
    serve(net, 'liar', {otherSha: src.path});
    final b = serve(net, 'b', {});
    final r = await b.fetch(otherSha, 50 * 1024, ['liar'], '${tmp.path}/bad.bin');
    expect(r.error, contains('fingerprint'));
    expect(File('${tmp.path}/bad.bin').existsSync(), isFalse);
  });

  group('serving rules', () {
    final member = generateSecretKey(), passHolder = generateSecretKey(), stranger = generateSecretKey();
    final serverKey = generateSecretKey();
    final pass = 'ab' * 32;

    BlobService server(
      LoopbackNetwork net,
      Map<String, String> files, {
      int allowance = 300 * 1024,
      int total = 500 * 1024,
    }) => BlobService(
      address: 'server',
      link: net.link(['server']),
      resolve: (sha) async => files[sha],
      chunkTimeout: const Duration(milliseconds: 300),
      rules: ServingRules(
        serverKey: toHex(publicKeyOf(serverKey)),
        freeAllowance: allowance,
        freeTotal: total,
        receiptSlack: 256 * 1024, // over the 8 chunks a reader has in flight
        passValid: (reader, p) async => reader == toHex(publicKeyOf(passHolder)) && p == pass,
        isMember: (reader) => reader == toHex(publicKeyOf(member)),
      ),
    );

    test('free readers get their allowance per key, and all of them share a daily cap', () async {
      final net = LoopbackNetwork();
      final (small, smallSha) = await randomFile('small.bin', 200 * 1024);
      final (big, bigSha) = await randomFile('big.bin', 400 * 1024);
      server(net, {smallSha: small.path, bigSha: big.path});
      final a = serve(net, 'a', {}), b = serve(net, 'b', {}), c = serve(net, 'c', {});
      final first = await a.fetch(smallSha, 200 * 1024, ['server'], '${tmp.path}/a1', reader: ReaderSession(stranger));
      expect(first.ok, isTrue, reason: first.error);
      final second = await a.fetch(bigSha, 400 * 1024, ['server'], '${tmp.path}/a2', reader: ReaderSession(stranger));
      expect(second.error, contains('allowance'), reason: 'the same key over its 300 KB');
      // Another key has its own allowance, until the 500 KB for all free
      // readers runs out.
      final other = await b.fetch(
        smallSha,
        200 * 1024,
        ['server'],
        '${tmp.path}/b1',
        reader: ReaderSession(generateSecretKey()),
      );
      expect(other.ok, isTrue, reason: other.error);
      final third = await c.fetch(smallSha, 200 * 1024, ['server'], '${tmp.path}/c1');
      expect(third.error, contains('no more free reading'), reason: 'a reader without a key counts by its address');
    });

    test('members read beyond the allowance', () async {
      final net = LoopbackNetwork();
      final (big, sha) = await randomFile('big.bin', 700 * 1024);
      server(net, {sha: big.path});
      final r = await serve(
        net,
        'm',
        {},
      ).fetch(sha, 700 * 1024, ['server'], '${tmp.path}/m', reader: ReaderSession(member));
      expect(r.ok, isTrue, reason: r.error);
    });

    test('a pass holder reads while its receipts keep up; the server keeps the latest to settle', () async {
      final net = LoopbackNetwork(dropRate: 0.05);
      final (big, sha) = await randomFile('big.bin', 900 * 1024);
      final s = server(net, {sha: big.path});
      final session = ReaderSession(passHolder, pass: pass, receiptEvery: 32 * 1024);
      final r = await serve(net, 'p', {}).fetch(sha, 900 * 1024, ['server'], '${tmp.path}/p', reader: session);
      expect(r.ok, isTrue, reason: r.error);
      expect(session.status['server'], ReaderStatus.pass);
      // The final receipt travels after the download; wait for it.
      for (var i = 0; i < 50 && (s.receipts[pass]?.bytes ?? 0) < 900 * 1024; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      final receipt = s.receipts[pass]!;
      expect(receipt.bytes, 900 * 1024);
      expect(receipt.server, toHex(publicKeyOf(serverKey)));
      expect(receipt.verify(toHex(publicKeyOf(passHolder))), isTrue, reason: 'settles on the chain');
    });

    test('a pass holder that stops signing receipts is stopped', () async {
      final net = LoopbackNetwork();
      final (big, sha) = await randomFile('big.bin', 900 * 1024);
      server(net, {sha: big.path});
      final session = ReaderSession(passHolder, pass: pass, sendReceipts: false);
      final r = await serve(net, 'p', {}).fetch(sha, 900 * 1024, ['server'], '${tmp.path}/p', reader: session);
      expect(r.error, contains('receipts'));
    });
  });
}
