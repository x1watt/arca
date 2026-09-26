// Packing (whitepaper, section 7): each steward stores every chunk XOR a
// keystream that only its own key and the chunk's position produce, and
// producing it costs a memory-hard function (Argon2id here; RandomX is a
// later choice). One disk cannot answer for two stewards, and making the
// bytes on demand costs far more than reading them.
//
// Keystream of a chunk = SHA-256(seed || counter) blocks, where seed =
// Argon2id(key || partition || index). A single 1 KB slice needs the seed
// and 32 hashes, so a proof is cheap to check.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as c;
import 'package:cryptography/cryptography.dart';

import 'params.dart';

final _salt = utf8.encode('arca-packing-v1!');

/// The seed of the keystream for chunk [index] of [partition] packed by
/// [stewardPubkey] (hex).
Future<Uint8List> packSeed(ChainParams params, String stewardPubkey, int partition, int index) async {
  final input = utf8.encode('$stewardPubkey:$partition:$index');
  final key = await Argon2id(
    memory: params.packMemoryKiB,
    parallelism: 1,
    iterations: 1,
    hashLength: 32,
  ).deriveKey(secretKey: SecretKey(input), nonce: _salt);
  return Uint8List.fromList(await key.extractBytes());
}

/// [length] bytes of the keystream from byte [offset] (multiple of 32).
Uint8List keystream(Uint8List seed, int offset, int length) {
  final out = Uint8List(length);
  final counter = ByteData(4);
  for (var o = 0; o < length; o += 32) {
    counter.setUint32(0, (offset + o) ~/ 32);
    final block = c.sha256.convert([...seed, ...counter.buffer.asUint8List()]).bytes;
    out.setRange(o, (o + 32).clamp(0, length), block);
  }
  return out;
}

/// XORs [data] (at [offset] in the chunk) with the keystream: packs or
/// unpacks, the same operation both ways.
Uint8List xorStream(Uint8List data, Uint8List seed, int offset) {
  final ks = keystream(seed, offset, data.length);
  return Uint8List.fromList([for (var i = 0; i < data.length; i++) data[i] ^ ks[i]]);
}

/// A steward's packed copy of one partition: fixed slots of one chunk each,
/// short last chunks padded with zeros before packing.
class PackedPartition {
  PackedPartition(this.path);
  final String path;

  /// Writes chunk [index] (plain bytes) packed with [seed].
  Future<void> write(RandomAccessFile out, int index, Uint8List chunk, Uint8List seed) async {
    final padded = Uint8List(ChainParams.chunkBytes)..setRange(0, chunk.length, chunk);
    await out.setPosition(index * ChainParams.chunkBytes);
    await out.writeFrom(xorStream(padded, seed, 0));
  }

  /// Reads packed slice [slice] of chunk [index].
  Future<Uint8List> readSlice(int index, int slice) async {
    final f = await File(path).open();
    try {
      await f.setPosition(index * ChainParams.chunkBytes + slice * ChainParams.sliceBytes);
      return await f.read(ChainParams.sliceBytes);
    } finally {
      await f.close();
    }
  }
}
