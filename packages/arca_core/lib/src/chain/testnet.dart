// A testnet anyone can start without a server (docs/architecture.md, 10):
// a founder picks one of their public collections as the corpus, becomes
// the admin of the genesis circle and gets a test allocation; everything
// else follows the chain's rules. Others join with an invite naming the
// spec's hash and an address that serves it; they keep a copy of the
// collection with the usual sync, rebuild the corpus and check its root.
//
//   arca-chain:<spec hash>:<arca address>

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as c;

import '../library/library.dart' show hashFile;
import 'corpus.dart';
import 'params.dart';
import 'state.dart';
import 'tx.dart' show canonicalJson;

/// Marcas the founder starts with, to try sending and passes.
const testnetAllocation = 10000 * ChainParams.grainsPerMarca;

/// Interest seed of the genesis corpus.
const testnetSeed = 1000 * ChainParams.grainsPerMarca;

class TestnetSpec {
  TestnetSpec(this.json);

  final Map<String, Object?> json;

  factory TestnetSpec.create({
    required String founder,
    required String collectionOwner,
    required String collectionId,
    required String collectionName,
    required List<(String sha256, int size)> files,
    required String corpusRoot,
    required List<int> partitionSizes,
    int? genesisTick,
    ChainParams params = ChainParams.testnet,
  }) => TestnetSpec({
    'version': 1,
    'params': params.toJson(),
    'genesisTick': genesisTick ?? DateTime.now().millisecondsSinceEpoch ~/ params.tickMillis,
    'founder': founder,
    'circle': {'id': 'commons', 'name': 'Arca Commons'},
    'corpus': {
      'owner': collectionOwner,
      'collection': collectionId,
      'name': collectionName,
      'files': [
        for (final (sha, size) in files) [sha, size],
      ],
      'root': corpusRoot,
      'partitionSizes': partitionSizes,
    },
  });

  String get hash => c.sha256.convert(utf8.encode(canonicalJson(json))).toString();

  ChainParams get params => ChainParams.fromJson(json['params'] as Map);
  int get genesisTick => json['genesisTick'] as int;
  String get founder => json['founder'] as String;
  Map get _corpus => json['corpus'] as Map;
  String get corpusOwner => _corpus['owner'] as String;
  String get corpusCollection => _corpus['collection'] as String;
  String get corpusName => _corpus['name'] as String;
  String get corpusRoot => _corpus['root'] as String;
  List<int> get partitionSizes => (_corpus['partitionSizes'] as List).cast<int>();
  List<(String, int)> get files => [for (final f in _corpus['files'] as List) ((f as List)[0] as String, f[1] as int)];
  String get circleId => (json['circle'] as Map)['id'] as String;

  /// The chain's first state: the genesis circle, the corpus as one seeded
  /// collection, and the founder's allocation.
  ChainState genesis() => ChainState.genesis(
    params,
    allocations: {founder: testnetAllocation},
    circles: {circleId: CircleState(admin: founder, name: (json['circle'] as Map)['name'] as String)},
    collections: {
      'corpus': CollectionState(
        circle: circleId,
        partitions: [for (var i = 0; i < partitionSizes.length; i++) i],
        seed: testnetSeed,
      ),
    },
    corpusRoot: corpusRoot,
    partitionSizes: partitionSizes,
    genesisTick: genesisTick,
  );

  static String invite(String specHash, String arcaAddress) => 'arca-chain:$specHash:$arcaAddress';

  /// (spec hash, arca address) of an invite, or null.
  static (String, String)? parseInvite(String invite) {
    final m = RegExp(r'^arca-chain:([0-9a-f]{64}):(arca:.+)$').firstMatch(invite.trim());
    return m == null ? null : (m.group(1)!, m.group(2)!);
  }
}

/// Builds the corpus of [files] (SHA-256 to path, all of them present).
Future<Corpus> buildCorpus(ChainParams params, Map<String, String> files) async {
  final chunked = <ChunkedFile>[];
  for (final e in files.entries) {
    chunked.add(await chunkFile(File(e.value), e.key));
  }
  return Corpus.build(params, chunked);
}

/// Hashes [paths] and builds their corpus; returns what a spec needs.
Future<(List<(String, int)>, Corpus, Map<String, String>)> corpusOfPaths(ChainParams params, List<String> paths) async {
  final files = <String, String>{};
  final sizes = <(String, int)>[];
  for (final p in paths) {
    final (sha, _, size) = await hashFile(File(p));
    if (files.containsKey(sha)) continue;
    files[sha] = p;
    sizes.add((sha, size));
  }
  sizes.sort((a, b) => a.$1.compareTo(b.$1));
  return (sizes, await buildCorpus(params, files), files);
}
