// The test network (docs/architecture.md, 10). Its spec (rules, genesis
// time, founder, corpus files and root) is built into the app like any
// chain's genesis, so nobody passes anything by hand: nodes find each other
// at an I2P address made from the spec's hash, which every full node
// answers for (a shared destination), and a node that keeps files fetches
// them by hash from the peers it found. The founder, who made the spec from
// one of their public collections with tool/seed_node.dart, is the admin of
// the genesis circle and gets a test allocation; everything else follows
// the chain's rules.

import 'dart:convert';
import 'dart:io';

import 'dart:typed_data';

import 'package:crypto/crypto.dart' as c;

import '../library/library.dart' show hashFile;
import 'corpus.dart';
import 'params.dart';
import 'state.dart';
import 'tx.dart' show canonicalJson;
import 'verify.dart' show Anchor;

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
    Map<String, String> names = const {},
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
        for (final (sha, size) in files) [sha, size, ?names[sha]],
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

  /// The corpus files' names by SHA-256, for the copy on disk; the hash
  /// when the spec has none.
  Map<String, String> get fileNames => {
    for (final f in _corpus['files'] as List)
      (f as List)[0] as String: f.length > 2 ? f[2] as String : f[0] as String,
  };
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

  /// The seeds of this network's meeting point: an I2P address anyone can
  /// work out from the spec, which every full node answers for, so a new
  /// node reaches whichever of them is online and learns the others. The
  /// keys are public by design; what arrives there is only ever a request
  /// for peers, and all else is checked against the chain.
  (Uint8List, Uint8List) get rendezvousSeeds => (
    Uint8List.fromList(c.sha256.convert(utf8.encode('arca-rendezvous-enc:$hash')).bytes),
    Uint8List.fromList(c.sha256.convert(utf8.encode('arca-rendezvous-sign:$hash')).bytes),
  );

  /// The test network built into this version of Arca, made by its seed
  /// node (docs/seed-node.md); null when there is none. ARCA_TESTNET_SPEC,
  /// the path of a spec file, replaces it (to try another network).
  static final TestnetSpec? builtIn = () {
    try {
      final path = Platform.environment['ARCA_TESTNET_SPEC'];
      final text = path != null ? File(path).readAsStringSync() : _builtInSpec;
      if (text.trim().isEmpty) return null;
      return TestnetSpec((jsonDecode(text) as Map).cast<String, Object?>());
    } on Object {
      return null;
    }
  }();

  /// The public test network's spec, as `tool/seed_node.dart` writes it.
  static const _builtInSpec = '';

  /// A recent block of the built-in network, as the seed node prints it
  /// for a release: a device checks the chain it is shown from here on
  /// (chain/verify.dart) and refuses any chain that does not contain it,
  /// so even a first run among nothing but forgers cannot be led onto
  /// another chain from before it. Null for none (checks start at genesis).
  static final Anchor? builtInCheckpoint = () {
    if (_builtInCheckpoint.trim().isEmpty || builtIn == null) return null;
    try {
      return Anchor.fromJson(jsonDecode(_builtInCheckpoint) as Map);
    } on Object {
      return null;
    }
  }();

  static const _builtInCheckpoint = '';
}

/// Builds the corpus of [files] (SHA-256 to path, all of them present).
Future<Corpus> buildCorpus(ChainParams params, Map<String, String> files) async {
  final chunked = <ChunkedFile>[];
  for (final e in files.entries) {
    chunked.add(await chunkFile(File(e.value), e.key));
  }
  return Corpus.build(params, chunked);
}

/// Hashes [paths] and builds their corpus; returns what a spec needs (the
/// files by hash and size, the corpus, and each file's path by hash).
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
