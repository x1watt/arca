// The corpus (whitepaper, section 7): every public file cut into 256 KB
// chunks, each chunk a Merkle tree of 1 KB slices, chunks laid end to end
// in a fixed order and grouped into partitions. A proof names a slice of
// a chunk of a partition, and anyone checks it against the corpus root.
//
// Testnet order: files sorted by SHA-256, each file once however many
// collections hold it. (The global corpus is append-only on mainnet; the
// order will follow anchors.)

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../crypto/hex.dart';
import 'merkle.dart';
import 'params.dart';

/// A file's chunk roots, computed while reading it once, in order.
class ChunkedFile {
  const ChunkedFile(this.sha256, this.size, this.chunkRoots);
  final String sha256;
  final int size;
  final List<Uint8List> chunkRoots;
}

/// The Merkle root of one chunk: its 1 KB slices as leaves.
Uint8List chunkRoot(Uint8List chunk) => merkleRoot(sliceLeaves(chunk));

List<Uint8List> sliceLeaves(Uint8List chunk) => [
  for (var o = 0; o < chunk.length; o += ChainParams.sliceBytes)
    leafHash(Uint8List.sublistView(chunk, o, (o + ChainParams.sliceBytes).clamp(0, chunk.length))),
];

/// Reads [f] once and returns its chunk roots.
Future<ChunkedFile> chunkFile(File f, String sha256) async {
  final roots = <Uint8List>[];
  final buffer = BytesBuilder(copy: false);
  var size = 0;
  await for (final part in f.openRead()) {
    buffer.add(part);
    size += part.length;
    while (buffer.length >= ChainParams.chunkBytes) {
      final all = buffer.takeBytes();
      roots.add(chunkRoot(Uint8List.sublistView(all, 0, ChainParams.chunkBytes)));
      buffer.add(Uint8List.sublistView(all, ChainParams.chunkBytes));
    }
  }
  if (buffer.length > 0 || size == 0) roots.add(chunkRoot(buffer.takeBytes()));
  return ChunkedFile(sha256, size, roots);
}

/// Where a chunk of the corpus comes from: a file and a byte range in it.
class ChunkSource {
  const ChunkSource(this.fileSha256, this.offset, this.length);
  final String fileSha256;
  final int offset;
  final int length;
}

class Corpus {
  Corpus._(this.params, this.files, this.chunks, this.sources, this.partitionRoots, this.root);

  final ChainParams params;
  final List<ChunkedFile> files;

  /// Every chunk root in corpus order, and where each chunk's bytes are.
  final List<Uint8List> chunks;
  final List<ChunkSource> sources;
  final List<Uint8List> partitionRoots;
  final Uint8List root;

  int get partitions => partitionRoots.length;

  /// Global chunk index of chunk [index] in [partition].
  int chunkIndex(int partition, int index) => partition * params.partitionChunks + index;

  /// Chunks in [partition].
  int chunksIn(int partition) {
    final start = partition * params.partitionChunks;
    return (chunks.length - start).clamp(0, params.partitionChunks);
  }

  List<Uint8List> partitionChunkRoots(int partition) {
    final start = partition * params.partitionChunks;
    return chunks.sublist(start, start + chunksIn(partition));
  }

  /// Builds the corpus from chunked files; the same file twice counts once.
  factory Corpus.build(ChainParams params, Iterable<ChunkedFile> input) {
    final bySha = <String, ChunkedFile>{for (final f in input) f.sha256: f};
    final files = bySha.values.toList()..sort((a, b) => a.sha256.compareTo(b.sha256));
    final chunks = <Uint8List>[];
    final sources = <ChunkSource>[];
    for (final f in files) {
      for (var i = 0; i < f.chunkRoots.length; i++) {
        chunks.add(f.chunkRoots[i]);
        final offset = i * ChainParams.chunkBytes;
        sources.add(ChunkSource(f.sha256, offset, (f.size - offset).clamp(0, ChainParams.chunkBytes)));
      }
    }
    final partitionRoots = <Uint8List>[
      for (var p = 0; p * params.partitionChunks < chunks.length; p++)
        merkleRoot(
          chunks.sublist(p * params.partitionChunks, ((p + 1) * params.partitionChunks).clamp(0, chunks.length)),
        ),
    ];
    return Corpus._(params, files, chunks, sources, partitionRoots, merkleRoot(partitionRoots));
  }

  String get rootHex => toHex(root);
}
