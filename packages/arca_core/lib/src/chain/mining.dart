// Clock-limited mining and holding proofs (whitepaper, section 7).
//
// Clock: ticks of wall time (ChainParams.tickMillis); a tick's challenge is
// SHA-256 of the previous block and the tick, so no producer can grind it
// by varying its own block, and a faster disk gains nothing: each steward
// reads one slice per declared partition per tick. (A verifiable delay
// function replaces the wall clock later; see docs/architecture.md, 10.)
//
// A proof names a slice of a chunk of a partition: the packed bytes the
// steward read, and the paths from that slice up to the corpus root. The
// verifier recomputes the steward's keystream for that chunk (the costly
// memory-hard part), unpacks the slice and climbs to the root.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as c;

import '../crypto/hex.dart';
import 'corpus.dart';
import 'merkle.dart';
import 'packing.dart';
import 'params.dart';

Uint8List _sha(List<Object> parts) => Uint8List.fromList(
  c.sha256.convert(utf8.encode(parts.map((p) => p is List<int> ? toHex(p) : '$p').join('|'))).bytes,
);

BigInt _num(Uint8List h) => BigInt.parse(toHex(h), radix: 16);

/// The largest target: every proof qualifies.
final maxTarget = (BigInt.one << 256) - BigInt.one;

/// Challenge of [tick] on top of block [prev] (hex hash; '' for genesis).
Uint8List mineChallenge(String prev, int tick) => _sha(['arca-mine', prev, tick]);

/// Challenge of a steward's daily holding proof for [partition].
Uint8List holdChallenge(String beacon, int day, String steward, int partition) =>
    _sha(['arca-hold', beacon, day, steward, partition]);

/// The chunk and slice a challenge names in a partition of [chunks] chunks;
/// the slice is chosen once the chunk's length is known.
int challengedChunk(Uint8List challenge, int partition, int chunks) =>
    (_num(_sha([challenge, partition])) % BigInt.from(chunks)).toInt();

int challengedSlice(Uint8List challenge, int partition, int chunk, int chunkLength) {
  final slices = (chunkLength + ChainParams.sliceBytes - 1) ~/ ChainParams.sliceBytes;
  return (_num(_sha([challenge, partition, chunk])) % BigInt.from(slices < 1 ? 1 : slices)).toInt();
}

/// How good a proof is: lower is better; a mining proof must be below the
/// state's target.
BigInt proofQuality(Uint8List challenge, String steward, Uint8List packedSlice) =>
    _num(_sha(['arca-quality', challenge, steward, packedSlice]));

/// The work a block mined against [target] stands for: how many tries it
/// takes on average to get under it (1 at the largest target).
BigInt expectedWork(BigInt target) => (maxTarget + BigInt.one) ~/ (target + BigInt.one);

List<List<Object>> _path(List<ProofStep> p) => [
  for (final (h, right) in p) [toHex(h), right],
];

List<ProofStep> _unpath(Object? j) => [for (final s in j as List) (fromHex((s as List)[0] as String), s[1] as bool)];

class SliceProof {
  const SliceProof({
    required this.steward,
    required this.circle,
    required this.partition,
    required this.chunk,
    required this.chunkLength,
    required this.slice,
    required this.packed,
    required this.slicePath,
    required this.chunkPath,
    required this.partitionPath,
  });

  final String steward;
  final String circle;
  final int partition;
  final int chunk;
  final int chunkLength;
  final int slice;
  final Uint8List packed;
  final List<ProofStep> slicePath;
  final List<ProofStep> chunkPath;
  final List<ProofStep> partitionPath;

  Map<String, Object?> toJson() => {
    'steward': steward,
    'circle': circle,
    'partition': partition,
    'chunk': chunk,
    'chunkLength': chunkLength,
    'slice': slice,
    'packed': toHex(packed),
    'slicePath': _path(slicePath),
    'chunkPath': _path(chunkPath),
    'partitionPath': _path(partitionPath),
  };

  factory SliceProof.fromJson(Map m) => SliceProof(
    steward: m['steward'] as String,
    circle: m['circle'] as String,
    partition: m['partition'] as int,
    chunk: m['chunk'] as int,
    chunkLength: m['chunkLength'] as int,
    slice: m['slice'] as int,
    packed: fromHex(m['packed'] as String),
    slicePath: _unpath(m['slicePath']),
    chunkPath: _unpath(m['chunkPath']),
    partitionPath: _unpath(m['partitionPath']),
  );

  /// Checks the proof answers [challenge] and leads to [corpusRoot] given
  /// the partition sizes; null when it holds, otherwise why not.
  Future<String?> check(ChainParams params, Uint8List challenge, String corpusRoot, List<int> partitionSizes) async {
    if (partition < 0 || partition >= partitionSizes.length) return 'no such partition';
    if (chunk != challengedChunk(challenge, partition, partitionSizes[partition])) return 'not the challenged chunk';
    if (chunkLength <= 0 || chunkLength > ChainParams.chunkBytes) return 'bad chunk length';
    if (slice != challengedSlice(challenge, partition, chunk, chunkLength)) return 'not the challenged slice';
    if (packed.length != ChainParams.sliceBytes) return 'a slice is 1 KB';
    final seed = await packSeed(params, steward, partition, chunk);
    final plain = xorStream(packed, seed, slice * ChainParams.sliceBytes);
    final real = (chunkLength - slice * ChainParams.sliceBytes).clamp(0, ChainParams.sliceBytes);
    final slices = (chunkLength + ChainParams.sliceBytes - 1) ~/ ChainParams.sliceBytes;
    final chunkRoot = merkleClimb(leafHash(Uint8List.sublistView(plain, 0, real)), slice, slices, slicePath);
    if (chunkRoot == null) return 'bad path inside the chunk';
    final partitionRoot = merkleClimb(chunkRoot, chunk, partitionSizes[partition], chunkPath);
    if (partitionRoot == null) return 'bad path inside the partition';
    final root = merkleClimb(partitionRoot, partition, partitionSizes.length, partitionPath);
    if (root == null || toHex(root) != corpusRoot) return 'does not lead to the corpus';
    return null;
  }
}

/// A steward's side: its packed partitions and the corpus they come from.
class Steward {
  Steward({required this.params, required this.key, required this.corpus, required this.folder, required this.files});

  final ChainParams params;

  /// The steward's public key (hex).
  final String key;
  final Corpus corpus;

  /// Where packed partitions live: `<folder>/<partition>.packed`.
  final String folder;

  /// Plain copies of the corpus files, by SHA-256 (to build proof paths).
  final Map<String, String> files;

  String packedPath(int partition) => '$folder/$partition.packed';

  /// Packs [partition] from the plain files. Costly: run it off the main
  /// isolate (one Argon2id per chunk).
  Future<void> pack(int partition) async {
    await Directory(folder).create(recursive: true);
    final out = await File(packedPath(partition)).open(mode: FileMode.write);
    final packed = PackedPartition(packedPath(partition));
    try {
      for (var i = 0; i < corpus.chunksIn(partition); i++) {
        final chunk = await _plainChunk(partition, i);
        await packed.write(out, i, chunk, await packSeed(params, key, partition, i));
      }
    } finally {
      await out.close();
    }
  }

  Future<Uint8List> _plainChunk(int partition, int index) async {
    final src = corpus.sources[corpus.chunkIndex(partition, index)];
    final f = await File(files[src.fileSha256]!).open();
    try {
      await f.setPosition(src.offset);
      return await f.read(src.length);
    } finally {
      await f.close();
    }
  }

  /// The packed slice [challenge] names in [partition]: cheap, one read.
  Future<(int chunk, int slice, Uint8List packed)> read(Uint8List challenge, int partition) async {
    final chunk = challengedChunk(challenge, partition, corpus.chunksIn(partition));
    final length = corpus.sources[corpus.chunkIndex(partition, chunk)].length;
    final slice = challengedSlice(challenge, partition, chunk, length);
    return (chunk, slice, await PackedPartition(packedPath(partition)).readSlice(chunk, slice));
  }

  /// A full proof for the slice [challenge] names in [partition].
  Future<SliceProof> prove(Uint8List challenge, int partition, String circle) async {
    final (chunk, slice, packed) = await read(challenge, partition);
    final plain = await _plainChunk(partition, chunk);
    final leaves = sliceLeaves(plain);
    return SliceProof(
      steward: key,
      circle: circle,
      partition: partition,
      chunk: chunk,
      chunkLength: plain.length,
      slice: slice,
      packed: packed,
      slicePath: merkleProof(leaves, slice),
      chunkPath: merkleProof(corpus.partitionChunkRoots(partition), chunk),
      partitionPath: merkleProof(corpus.partitionRoots, partition),
    );
  }
}
