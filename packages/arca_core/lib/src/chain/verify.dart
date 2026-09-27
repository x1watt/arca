// Checking a chain before trusting it (docs/architecture.md, 10). A new
// node meets peers it has no reason to trust: anyone can answer at the
// network's meeting point, and a node that met only attackers would get no
// fraud proof to warn it. So it trusts no checkpoint a peer hands it. From
// an anchor it does trust (the genesis in the app, or a checkpoint built
// into this release) it takes the peer's header summaries, checks that
// each follows the last (height, hash, clock, signature) and adds up the
// work they claim. Then it checks the mining proofs of a sample, drawn in
// proportion to the work each block claims, with the memory-hard part:
// the slice must be the corpus's, packed under the producer's key. A chain
// whose work is largely invented fails the sample with near certainty; a
// real one costs its producers real storage over real time, like any
// proof-of-work chain. The node follows the heaviest chain that holds.
//
// Checking one proof costs one Argon2id (docs/performance.md, 3.15), so
// only a sample is checked: the newest blocks, and [samples] more.

import 'dart:math';

import 'fraud.dart';
import 'mining.dart';
import 'params.dart';

/// Where a check starts: a block trusted without checking (genesis, or a
/// checkpoint built into this release) and the work up to it.
class Anchor {
  const Anchor({required this.hash, required this.height, required this.tick, required this.work});

  /// The genesis of a chain whose first tick is [genesisTick].
  Anchor.genesis(int genesisTick) : this(hash: '', height: 0, tick: genesisTick - 1, work: BigInt.zero);

  factory Anchor.fromJson(Map m) =>
      Anchor(hash: m['hash'] as String, height: m['height'] as int, tick: m['tick'] as int, work: BigInt.parse('${m['work']}'));

  Map<String, Object?> toJson() => {'hash': hash, 'height': height, 'tick': tick, 'work': '$work'};

  final String hash;
  final int height;
  final int tick;
  final BigInt work;
}

/// The result of checking a chain: its total work, or why it fails.
class Checked {
  const Checked.ok(this.work, this.tip) : error = null;
  const Checked.fail(this.error) : work = null, tip = null;

  final BigInt? work;

  /// The last header checked.
  final Header? tip;
  final String? error;
  bool get ok => error == null;
}

class ChainChecker {
  ChainChecker({
    required this.params,
    required this.corpusRoot,
    required this.partitionSizes,
    this.recent = 8,
    this.samples = 24,
    Random? random,
    int Function()? currentTick,
  }) : _rng = random ?? Random.secure(),
       _currentTick = currentTick ?? (() => DateTime.now().millisecondsSinceEpoch ~/ params.tickMillis);

  final ChainParams params;
  final String corpusRoot;
  final List<int> partitionSizes;

  /// The newest blocks, all checked in full; then [samples] more drawn by
  /// work from the rest.
  final int recent;
  final int samples;
  final Random _rng;
  final int Function() _currentTick;

  /// Checks [chain] (summaries or full headers, oldest first, following
  /// [anchor]). [full] fetches a sampled header with its proof (from any
  /// peer: it must match the summary's hash), null when none has it.
  Future<Checked> check(Anchor anchor, List<Header> chain, Future<Header?> Function(Header summary) full) async {
    var prevHash = anchor.hash, prevHeight = anchor.height, prevTick = anchor.tick;
    var work = anchor.work;
    final cumulative = <BigInt>[];
    final now = _currentTick();
    for (final h in chain) {
      if (h.height != prevHeight + 1) return Checked.fail('block ${h.height} does not follow ${prevHeight}');
      if (h.prev != prevHash) return Checked.fail('block ${h.height} names another parent');
      if (h.tick <= prevTick) return Checked.fail('block ${h.height} is not later than its parent');
      if (h.tick > now + 2) return Checked.fail('block ${h.height} is from the future');
      if (!h.signed) return Checked.fail('block ${h.height} is not signed by its producer');
      work += h.work;
      cumulative.add(work);
      prevHash = h.hash;
      prevHeight = h.height;
      prevTick = h.tick;
    }
    if (chain.isEmpty) return Checked.ok(work, null);
    // Which blocks to check in full: the newest, and a draw by work.
    final picked = <int>{for (var i = max(0, chain.length - recent); i < chain.length; i++) i};
    final base = anchor.work, span = work - anchor.work;
    for (var k = 0; k < samples && picked.length < chain.length && span > BigInt.zero; k++) {
      final at = base + _below(span);
      picked.add(_firstReaching(cumulative, at));
    }
    for (final i in picked.toList()..sort()) {
      final s = chain[i];
      if (s.proofHash.isEmpty) continue; // no proof, worth one
      final f = s.isSummary ? await full(s) : s;
      if (f == null) return Checked.fail('nobody showed the proof of block ${s.height}');
      if (f.hash != s.hash) return Checked.fail('the proof shown for block ${s.height} is not its own');
      final why = await _checkProof(f);
      if (why != null) return Checked.fail('block ${s.height}: $why');
    }
    return Checked.ok(work, chain.last);
  }

  /// Whether [h]'s mining proof holds: the producer's, under the target it
  /// claims, answering its tick's challenge with a slice of the corpus
  /// packed under the producer's key.
  Future<String?> _checkProof(Header h) async {
    final SliceProof proof;
    try {
      proof = SliceProof.fromJson(h.proof);
    } on Object {
      return 'its proof cannot be read';
    }
    if (proof.keeper != h.producer) return 'its proof is another keeper\'s';
    if (h.quality >= h.target) return 'its proof does not meet the target it claims';
    return proof.check(params, mineChallenge(h.prev, h.tick), corpusRoot, partitionSizes);
  }

  /// A random number below [n].
  BigInt _below(BigInt n) {
    final bytes = (n.bitLength + 7) ~/ 8 + 8;
    var r = BigInt.zero;
    for (var i = 0; i < bytes; i++) {
      r = (r << 8) | BigInt.from(_rng.nextInt(256));
    }
    return r % n;
  }

  /// The first index whose cumulative work reaches past [at].
  static int _firstReaching(List<BigInt> cumulative, BigInt at) {
    var lo = 0, hi = cumulative.length - 1;
    while (lo < hi) {
      final mid = (lo + hi) ~/ 2;
      if (cumulative[mid] > at) {
        hi = mid;
      } else {
        lo = mid + 1;
      }
    }
    return lo;
  }
}
