// Blocks (whitepaper, section 6). The header commits to the previous block,
// the clock tick, the transactions, the state that results from them, the
// corpus and the producer's mining proof. A node applies a block to a copy
// of its state and accepts it only if the mining proof holds, every
// transaction is valid and the resulting root is the one the producer
// signed: a wrong state is a rejected block.

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as c;

import '../crypto/hex.dart';
import '../crypto/schnorr.dart';
import 'merkle.dart';
import 'mining.dart';
import 'state.dart';
import 'tx.dart';

class Block {
  const Block({
    required this.height,
    required this.prev,
    required this.tick,
    required this.producer,
    required this.txs,
    required this.txRoot,
    required this.stateRoot,
    required this.corpusRoot,
    required this.proof,
    required this.sig,
  });

  final int height;
  final String prev;
  final int tick;
  final String producer;
  final List<Tx> txs;
  final String txRoot;
  final String stateRoot;
  final String corpusRoot;

  /// The producer's mining proof: the slice that won this tick (empty while
  /// the chain has no corpus yet).
  final Map<String, Object?> proof;
  final String sig;

  static String txsRoot(List<Tx> txs) => toHex(merkleRoot([for (final t in txs) leafHash(fromHex(t.id))]));

  static Uint8List _headerBytes(
    int height,
    String prev,
    int tick,
    String producer,
    String txRoot,
    String stateRoot,
    String corpusRoot,
    Map<String, Object?> proof,
  ) => Uint8List.fromList(
    c.sha256
        .convert(
          utf8.encode(
            canonicalJson(['arca-block-v1', height, prev, tick, producer, txRoot, stateRoot, corpusRoot, proof]),
          ),
        )
        .bytes,
  );

  String get hash => toHex(_headerBytes(height, prev, tick, producer, txRoot, stateRoot, corpusRoot, proof));

  /// The quality of this block's mining proof (lower is better); the
  /// largest value for a block without one. Breaks ties between forks.
  BigInt get quality {
    if (proof.isEmpty) return maxTarget;
    final p = SliceProof.fromJson(proof);
    return proofQuality(mineChallenge(prev, tick), p.steward, p.packed);
  }

  /// The state after [txs] on top of [state] at [tick] with mining [proof];
  /// with [strict] a bad transaction fails the whole block, otherwise it is
  /// left out (when producing). Returns the state and the included txs.
  static Future<(ChainState, List<Tx>)> _transition(
    ChainState state,
    int tick,
    String producer,
    Map<String, Object?> proof,
    List<Tx> txs, {
    required bool strict,
  }) async {
    final params = state.params;
    if (tick <= state.tick && state.height > 0) throw const ChainError('the clock went backwards');
    final next = state.copy();
    next.startDay(state.dayOf(tick));
    if (state.corpusRoot.isNotEmpty && next.declarations.isNotEmpty) {
      // Mining proof: a slice of a partition this producer declared, for
      // the circle it names, below the target. (Before anyone declares, at
      // the very start, blocks carry no proof and add almost no work, so
      // any mined chain outweighs them.)
      if (proof.isEmpty) throw const ChainError('a block needs a mining proof');
      final p = SliceProof.fromJson(proof);
      if (p.steward != producer) throw const ChainError('the proof is not the producer\'s');
      if (next.declarations[producer]?[p.partition] != p.circle) {
        throw const ChainError('the producer did not declare that partition');
      }
      final challenge = mineChallenge(state.head, tick);
      final why = await p.check(params, challenge, state.corpusRoot, state.partitionSizes);
      if (why != null) throw ChainError('bad mining proof: $why');
      if (proofQuality(challenge, producer, p.packed) >= state.target) throw const ChainError('proof above the target');
      // Retarget towards one block per blockTicks.
      if (state.height > 0) {
        final interval = tick - state.tick;
        if (interval < params.blockTicks) {
          next.target = state.target * BigInt.from(9) ~/ BigInt.from(10);
        } else if (interval > params.blockTicks) {
          final t = state.target * BigInt.from(11) ~/ BigInt.from(10);
          next.target = t > maxTarget ? maxTarget : t;
        }
      }
    }
    next.tick = tick;
    final included = <Tx>[];
    var result = next;
    for (final t in txs) {
      if (strict) {
        await result.apply(t);
        included.add(t);
        continue;
      }
      // Apply to a copy and keep it: each transaction is checked once
      // (a holding proof costs an Argon2id).
      final trial = result.copy();
      try {
        await trial.apply(t);
        result = trial;
        included.add(t);
      } on ChainError {
        continue;
      }
    }
    result
      ..height = state.height + 1
      ..head = '';
    return (result, included);
  }

  /// Builds and signs the next block on [state]. Invalid transactions are
  /// left out; [state] is not changed.
  static Future<Block> produce(
    ChainState state,
    List<int> secretKey,
    List<Tx> txs, {
    required int tick,
    Map<String, Object?> proof = const {},
  }) async {
    final producer = toHex(publicKeyOf(secretKey));
    final (next, included) = await _transition(state, tick, producer, proof, txs, strict: false);
    final txRoot = txsRoot(included);
    final stateRoot = next.rootHex;
    final header = _headerBytes(
      state.height + 1,
      state.head,
      tick,
      producer,
      txRoot,
      stateRoot,
      state.corpusRoot,
      proof,
    );
    return Block(
      height: state.height + 1,
      prev: state.head,
      tick: tick,
      producer: producer,
      txs: included,
      txRoot: txRoot,
      stateRoot: stateRoot,
      corpusRoot: state.corpusRoot,
      proof: proof,
      sig: toHex(schnorrSign(secretKey, header)),
    );
  }

  /// Applies this block to [state] and returns the new state, or throws
  /// [ChainError] naming the broken rule. [state] is never changed.
  Future<ChainState> applyTo(ChainState state) async {
    if (height != state.height + 1) throw ChainError('height $height after ${state.height}');
    if (prev != state.head) throw const ChainError('does not follow the current head');
    if (corpusRoot != state.corpusRoot) throw const ChainError('a different corpus');
    final header = _headerBytes(height, prev, tick, producer, txRoot, stateRoot, corpusRoot, proof);
    if (!schnorrVerify(fromHex(producer), header, fromHex(sig))) throw const ChainError('bad producer signature');
    if (txsRoot(txs) != txRoot) throw const ChainError('transactions do not match the header');
    final (next, _) = await _transition(state, tick, producer, proof, txs, strict: true);
    if (next.rootHex != stateRoot) throw const ChainError('the resulting state is not the one signed');
    next.head = hash;
    return next;
  }

  Map<String, Object?> toJson() => {
    'height': height,
    'prev': prev,
    'tick': tick,
    'producer': producer,
    'txs': [for (final t in txs) t.toJson()],
    'txRoot': txRoot,
    'stateRoot': stateRoot,
    'corpusRoot': corpusRoot,
    'proof': proof,
    'sig': sig,
  };

  factory Block.fromJson(Map m) => Block(
    height: m['height'] as int,
    prev: m['prev'] as String,
    tick: m['tick'] as int,
    producer: m['producer'] as String,
    txs: [for (final t in m['txs'] as List) Tx.fromJson(t as Map)],
    txRoot: m['txRoot'] as String,
    stateRoot: m['stateRoot'] as String,
    corpusRoot: m['corpusRoot'] as String,
    proof: (m['proof'] as Map).cast<String, Object?>(),
    sig: m['sig'] as String,
  );
}
