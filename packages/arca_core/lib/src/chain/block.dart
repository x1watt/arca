// Blocks (whitepaper, section 6). The header commits to the previous block,
// the clock tick, the target the mining proof had to meet, the
// transactions, the state that results from them, the trace of states on
// the way, the corpus and the producer's mining proof. A node applies a
// block to a copy of its state and accepts it only if the mining proof
// holds, every transaction is valid and every root is the one the producer
// signed: a wrong state is a rejected block.
//
// The trace is the state root after the block's prelude (closing a day,
// the mining proof, the new target) and after each transaction. A light
// client that holds only headers can be shown one wrong step of it, with
// the few entries that step touches (fraud.dart).
//
// A block's state commits `head` as '' (its own hash is not known yet); the
// next block starts from it with `head` set to that hash.

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as c;

import '../crypto/hex.dart';
import '../crypto/schnorr.dart';
import 'merkle.dart';
import 'mining.dart';
import 'signer.dart';
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
    required this.target,
    required this.traceRoot,
    required this.trace,
    this.headerTxCount,
  });

  /// For a block known only by its header (a checkpoint): how many
  /// transactions the header names, so its hash stays the same.
  final int? headerTxCount;

  final int height;
  final String prev;
  final int tick;
  final String producer;
  final List<Tx> txs;
  final String txRoot;
  final String stateRoot;
  final String corpusRoot;

  /// The target the mining proof had to meet (the parent state's), so a
  /// light client can weigh forks from headers alone.
  final BigInt target;

  /// The trace: the state root after the prelude and after each
  /// transaction; the header commits to its Merkle root.
  final List<String> trace;
  final String traceRoot;

  /// The producer's mining proof: the slice that won this tick (empty while
  /// the chain has no corpus yet).
  final Map<String, Object?> proof;
  final String sig;

  static String txsRoot(List<Tx> txs) => toHex(merkleRoot([for (final t in txs) leafHash(fromHex(t.id))]));

  static String traceRootOf(List<Uint8List> trace) => toHex(merkleRoot([for (final r in trace) leafHash(r)]));

  /// The signed part of the block: everything but the transactions.
  Map<String, Object?> get header => {
    'height': height,
    'prev': prev,
    'tick': tick,
    'producer': producer,
    'target': target.toRadixString(16),
    'txRoot': txRoot,
    'txCount': headerTxCount ?? txs.length,
    'stateRoot': stateRoot,
    'traceRoot': traceRoot,
    'corpusRoot': corpusRoot,
    'proof': proof,
  };

  static Uint8List _headerBytes(Map<String, Object?> header) =>
      Uint8List.fromList(c.sha256.convert(utf8.encode(canonicalJson(['arca-block-v2', header]))).bytes);

  String get hash => toHex(_headerBytes(header));

  /// The hash of a block with these [header] fields.
  static String hashOf(Map<String, Object?> header) => toHex(_headerBytes(header));

  /// Whether [sig] is the producer's signature over [header].
  static bool verifyHeader(Map<String, Object?> header, String sig) {
    try {
      return schnorrVerify(fromHex(header['producer'] as String), _headerBytes(header), fromHex(sig));
    } catch (_) {
      return false;
    }
  }

  /// Whether the producer signed this header.
  bool get signed {
    try {
      return schnorrVerify(fromHex(producer), _headerBytes(header), fromHex(sig));
    } catch (_) {
      return false;
    }
  }

  /// The quality of this block's mining proof (lower is better); the
  /// largest value for a block without one. Breaks ties between forks.
  BigInt get quality {
    if (proof.isEmpty) return maxTarget;
    final p = SliceProof.fromJson(proof);
    return proofQuality(mineChallenge(prev, tick), p.keeper, p.packed);
  }

  /// The block's first step on top of [state]: closes a day when one
  /// ended, checks the mining proof and sets the next target. Throws
  /// [ChainError] when the proof is wrong.
  static Future<ChainState> prelude(ChainState state, int tick, String producer, Map<String, Object?> proof) async {
    final params = state.params;
    if (tick <= state.tick && state.height > 0) throw const ChainError('the clock went backwards');
    final next = state.copy();
    next.startDay(state.dayOf(tick));
    if (state.corpusRoot.isNotEmpty && next.keepers > 0) {
      // Mining proof: a slice of a partition this producer declared, for
      // the circle it names, below the target. (Before anyone declares, at
      // the very start, blocks carry no proof and add almost no work, so
      // any mined chain outweighs them.)
      if (proof.isEmpty) throw const ChainError('a block needs a mining proof');
      final p = SliceProof.fromJson(proof);
      if (p.keeper != producer) throw const ChainError('the proof is not the producer\'s');
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
    next
      ..tick = tick
      ..height = state.height + 1
      ..head = '';
    return next;
  }

  /// The state after the prelude and [txs]; with [strict] a bad transaction
  /// fails the whole block, otherwise it is left out (when producing).
  /// Returns the state, the included transactions and the trace.
  static Future<(ChainState, List<Tx>, List<Uint8List>)> _transition(
    ChainState state,
    int tick,
    String producer,
    Map<String, Object?> proof,
    List<Tx> txs, {
    required bool strict,
  }) async {
    var result = await prelude(state, tick, producer, proof);
    final trace = [result.root()];
    final included = <Tx>[];
    for (final t in txs) {
      if (strict) {
        await result.apply(t);
      } else {
        // Apply to a copy and keep it: each transaction is checked once
        // (a holding proof costs an Argon2id).
        final trial = result.copy();
        try {
          await trial.apply(t);
        } on ChainError {
          continue;
        }
        result = trial;
      }
      included.add(t);
      trace.add(result.root());
    }
    return (result, included, trace);
  }

  /// Builds and signs the next block on [state]. Invalid transactions are
  /// left out; [state] is not changed.
  static Future<Block> produce(
    ChainState state,
    List<int> secretKey,
    List<Tx> txs, {
    required int tick,
    Map<String, Object?> proof = const {},
  }) => produceWith(state, LocalSigner(secretKey), txs, tick: tick, proof: proof);

  /// [produce], signed through [signer].
  static Future<Block> produceWith(
    ChainState state,
    Signer signer,
    List<Tx> txs, {
    required int tick,
    Map<String, Object?> proof = const {},
  }) async {
    final producer = signer.publicKey;
    final (next, included, trace) = await _transition(state, tick, producer, proof, txs, strict: false);
    final unsigned = Block(
      height: state.height + 1,
      prev: state.head,
      tick: tick,
      producer: producer,
      txs: included,
      txRoot: txsRoot(included),
      stateRoot: toHex(trace.last),
      corpusRoot: state.corpusRoot,
      proof: proof,
      sig: '',
      target: state.target,
      traceRoot: traceRootOf(trace),
      trace: [for (final r in trace) toHex(r)],
    );
    return unsigned._withSig(toHex(await signer.sign(_headerBytes(unsigned.header))));
  }

  /// This block signed by [secretKey] (tests build wrong blocks with it).
  Block signedBy(List<int> secretKey) => _withSig(toHex(schnorrSign(secretKey, _headerBytes(header))));

  Block _withSig(String sig) => Block(
    height: height,
    prev: prev,
    tick: tick,
    producer: producer,
    txs: txs,
    txRoot: txRoot,
    stateRoot: stateRoot,
    corpusRoot: corpusRoot,
    proof: proof,
    sig: sig,
    target: target,
    traceRoot: traceRoot,
    trace: trace,
  );

  /// Applies this block to [state] and returns the new state, or throws
  /// [ChainError] naming the broken rule. [state] is never changed.
  Future<ChainState> applyTo(ChainState state) async {
    if (height != state.height + 1) throw ChainError('height $height after ${state.height}');
    if (prev != state.head) throw const ChainError('does not follow the current head');
    if (corpusRoot != state.corpusRoot) throw const ChainError('a different corpus');
    if (target != state.target) throw const ChainError('not the target of the chain');
    if (!signed) throw const ChainError('bad producer signature');
    if (txsRoot(txs) != txRoot) throw const ChainError('transactions do not match the header');
    if (trace.length != txs.length + 1 || traceRootOf([for (final r in trace) fromHex(r)]) != traceRoot) {
      throw const ChainError('the trace does not match the header');
    }
    final (next, _, mine) = await _transition(state, tick, producer, proof, txs, strict: true);
    for (var i = 0; i < mine.length; i++) {
      if (toHex(mine[i]) != trace[i]) throw ChainError('step $i of the trace is wrong');
    }
    if (trace.last != stateRoot) throw const ChainError('the resulting state is not the one signed');
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
    'target': target.toRadixString(16),
    'traceRoot': traceRoot,
    'trace': trace,
    'headerTxCount': ?headerTxCount,
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
    target: BigInt.parse(m['target'] as String, radix: 16),
    traceRoot: m['traceRoot'] as String,
    trace: (m['trace'] as List).cast<String>(),
    headerTxCount: m['headerTxCount'] as int?,
  );
}
