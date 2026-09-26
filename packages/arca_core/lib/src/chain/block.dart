// Blocks (whitepaper, section 6). The header commits to the previous block,
// the clock tick, the transactions, the state that results from them and
// the corpus. A node applies a block to a copy of its state and accepts it
// only if every transaction is valid and the resulting root is the one the
// producer signed: a wrong state is a rejected block.

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as c;

import '../crypto/hex.dart';
import '../crypto/schnorr.dart';
import 'merkle.dart';
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

  /// The producer's mining proof (milestone 3): the slice that won the tick.
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

  /// Builds the next block on [state] with [txs] and signs it. Invalid
  /// transactions are left out; the state is not changed.
  static Block produce(
    ChainState state,
    List<int> secretKey,
    List<Tx> txs, {
    required int tick,
    String corpusRoot = '',
    Map<String, Object?> proof = const {},
  }) {
    final next = state.copy()..tick = tick;
    final included = <Tx>[];
    for (final t in txs) {
      final trial = next.copy();
      try {
        trial.apply(t);
        next.apply(t);
        included.add(t);
      } on ChainError {
        continue;
      }
    }
    next
      ..height = state.height + 1
      ..head = '';
    final producer = toHex(publicKeyOf(secretKey));
    final txRoot = txsRoot(included);
    final stateRoot = next.rootHex;
    final header = _headerBytes(state.height + 1, state.head, tick, producer, txRoot, stateRoot, corpusRoot, proof);
    return Block(
      height: state.height + 1,
      prev: state.head,
      tick: tick,
      producer: producer,
      txs: included,
      txRoot: txRoot,
      stateRoot: stateRoot,
      corpusRoot: corpusRoot,
      proof: proof,
      sig: toHex(schnorrSign(secretKey, header)),
    );
  }

  /// Applies this block to [state] and returns the new state, or throws
  /// [ChainError] naming the broken rule. [state] is never changed.
  ChainState applyTo(ChainState state) {
    if (height != state.height + 1) throw ChainError('height $height after ${state.height}');
    if (prev != state.head) throw const ChainError('does not follow the current head');
    if (tick <= state.tick && state.height > 0) throw const ChainError('the clock went backwards');
    final header = _headerBytes(height, prev, tick, producer, txRoot, stateRoot, corpusRoot, proof);
    if (!schnorrVerify(fromHex(producer), header, fromHex(sig))) throw const ChainError('bad producer signature');
    if (txsRoot(txs) != txRoot) throw const ChainError('transactions do not match the header');
    final next = state.copy()..tick = tick;
    for (final t in txs) {
      next.apply(t);
    }
    next
      ..height = height
      ..head = '';
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
