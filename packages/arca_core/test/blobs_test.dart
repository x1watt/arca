import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:arca_core/arca_core.dart';
import 'package:arca_core/src/transport/blobs.dart';
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
}
