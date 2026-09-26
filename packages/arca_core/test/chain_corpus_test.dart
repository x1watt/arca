import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:arca_core/src/chain/corpus.dart';
import 'package:arca_core/src/chain/merkle.dart';
import 'package:arca_core/src/chain/packing.dart';
import 'package:arca_core/src/chain/params.dart';
import 'package:test/test.dart';

Uint8List bytes(int n, int seed) {
  final r = Random(seed);
  return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
}

void main() {
  test('merkle proofs verify for every leaf of odd and even trees, and fail when tampered', () {
    for (final n in [1, 2, 3, 5, 8, 13]) {
      final leaves = [
        for (var i = 0; i < n; i++) leafHash([i]),
      ];
      final root = merkleRoot(leaves);
      for (var i = 0; i < n; i++) {
        final path = merkleProof(leaves, i);
        expect(merkleVerify(leaves[i], path, root), isTrue, reason: 'n=$n i=$i');
        expect(merkleVerify(leafHash([99]), path, root), isFalse);
      }
    }
  });

  test('corpus: chunks, partitions and one root; the same file counts once', () async {
    final tmp = await Directory.systemTemp.createTemp('arca_corpus');
    const p = ChainParams.testnet;
    final a = File('${tmp.path}/a')..writeAsBytesSync(bytes(600 * 1024, 1));
    final b = File('${tmp.path}/b')..writeAsBytesSync(bytes(10, 2));
    final ca = await chunkFile(a, 'aa'), cb = await chunkFile(b, 'bb');
    expect(ca.chunkRoots.length, 3);
    expect(cb.chunkRoots.length, 1);
    final corpus = Corpus.build(p, [ca, cb, ca]);
    expect(corpus.chunks.length, 4);
    expect(corpus.partitions, 1);
    expect(corpus.sources.last.length, 10);
    expect(Corpus.build(p, [cb, ca]).rootHex, corpus.rootHex, reason: 'order independent of input');
    await tmp.delete(recursive: true);
  });

  test('packing: round trip, unique per steward, and a slice proves up to the corpus root', () async {
    const p = ChainParams.testnet;
    final chunk = bytes(ChainParams.chunkBytes, 3);
    final seedA = await packSeed(p, 'a' * 64, 0, 0);
    final seedB = await packSeed(p, 'b' * 64, 0, 0);
    final packedA = xorStream(chunk, seedA, 0), packedB = xorStream(chunk, seedB, 0);
    expect(packedA, isNot(equals(packedB)), reason: 'one disk cannot answer for two stewards');
    expect(xorStream(packedA, seedA, 0), chunk);

    // A proof: packed slice 7 of this chunk, unpacked with the steward's
    // seed (recomputed by the verifier), checked against the chunk root,
    // then the chunk against the partition, the partition against the corpus.
    const slice = 7;
    final packedSlice = Uint8List.sublistView(packedA, slice * 1024, (slice + 1) * 1024);
    final plain = xorStream(Uint8List.fromList(packedSlice), await packSeed(p, 'a' * 64, 0, 0), slice * 1024);
    final leaves = sliceLeaves(chunk);
    final cRoot = merkleRoot(leaves);
    expect(merkleVerify(leafHash(plain), merkleProof(leaves, slice), cRoot), isTrue);
    final other = [
      cRoot,
      leafHash([1]),
      leafHash([2]),
    ];
    final partRoot = merkleRoot(other);
    expect(merkleVerify(cRoot, merkleProof(other, 0), partRoot), isTrue);
    // The wrong steward's seed does not unpack it.
    final wrong = xorStream(Uint8List.fromList(packedSlice), seedB, slice * 1024);
    expect(merkleVerify(leafHash(wrong), merkleProof(leaves, slice), cRoot), isFalse);
  });
}
