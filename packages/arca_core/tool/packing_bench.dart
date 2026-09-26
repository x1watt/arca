// Packing benchmark (whitepaper, section 7 and step 3 of section 12): how
// much more it costs to make a packed slice on demand than to read it from
// the packed copy on disk. The whitepaper asks for 1,000 to 10,000 times.
//
//   dart run tool/packing_bench.dart <scratch dir> [chunks] [KiB,KiB,...]
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:arca_core/src/chain/packing.dart';
import 'package:arca_core/src/chain/params.dart';

Future<void> main(List<String> args) async {
  final dir = args.isNotEmpty ? args[0] : Directory.systemTemp.path;
  final chunks = args.length > 1 ? int.parse(args[1]) : 16;
  final rng = Random(1);
  final data = Uint8List.fromList(List.generate(ChainParams.chunkBytes, (_) => rng.nextInt(256)));
  print('${Platform.operatingSystem}, ${Platform.numberOfProcessors} threads, $chunks chunks of 256 KB');
  final memories = args.length > 2 ? [for (final m in args[2].split(",")) int.parse(m)] : [8192, 32768, 65536];
  for (final mem in memories) {
    final params = ChainParams(
      name: 'bench',
      partitionChunks: chunks,
      tickMillis: 1000,
      blockTicks: 1,
      dayTicks: 1,
      packMemoryKiB: mem,
      dailyIssuance: 0,
      halvingDays: 1,
      floorIssuance: 0,
      circleFee: 0,
      fraudWindowTicks: 1,
    );
    final path = '$dir/bench-$mem.packed';
    final out = await File(path).open(mode: FileMode.write);
    final part = PackedPartition(path);
    final sw = Stopwatch()..start();
    var seedMs = 0;
    for (var i = 0; i < chunks; i++) {
      final s = Stopwatch()..start();
      final seed = await packSeed(params, 'a' * 64, 0, i);
      seedMs += s.elapsedMilliseconds;
      await part.write(out, i, data, seed);
    }
    await out.close();
    final packMs = sw.elapsedMilliseconds;
    // Reading a slice from the packed copy (page cache warm: the best case
    // for the honest steward, so the ratio is conservative).
    const reads = 2000;
    sw
      ..reset()
      ..start();
    for (var i = 0; i < reads; i++) {
      await part.readSlice(rng.nextInt(chunks), rng.nextInt(ChainParams.slicesPerChunk));
    }
    final readUs = sw.elapsedMicroseconds / reads;
    // Making the same slice without the packed copy: seed plus keystream.
    const regens = 8;
    sw
      ..reset()
      ..start();
    for (var i = 0; i < regens; i++) {
      final seed = await packSeed(params, 'a' * 64, 0, i);
      keystream(seed, 0, ChainParams.sliceBytes);
    }
    final regenUs = sw.elapsedMicroseconds / regens;
    final mbps = chunks * 256 / 1024 / (packMs / 1000);
    print(
      'Argon2id ${mem ~/ 1024} MB: seed ${(seedMs / chunks).toStringAsFixed(0)} ms/chunk, '
      'packing ${mbps.toStringAsFixed(2)} MB/s (${(1024 / mbps / 3600).toStringAsFixed(1)} h per GB), '
      'slice read ${readUs.toStringAsFixed(0)} us, slice remade ${(regenUs / 1000).toStringAsFixed(0)} ms, '
      'ratio ${(regenUs / readUs).toStringAsFixed(0)}x',
    );
    await File(path).delete();
  }
}
