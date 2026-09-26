// Fraud proofs (whitepaper, section 6): how a full node shows a light
// client, which holds only headers, that a block is wrong.
//
// A block's trace names the state root after each step: the prelude
// (closing a day, the mining proof, the new target) and each transaction.
// A proof picks the first wrong step and carries:
//
// - the headers of the block and its parent;
// - the state root before the step (the parent's state root, or the trace
//   entry before, with its Merkle path) and the roots of its namespaces;
// - the transaction, with its path in the block's transactions (for a
//   transaction step);
// - the entries the step touches, each proven present or absent in its
//   namespace; a namespace the step goes through as a whole (a day's
//   settlement goes through every keeper) comes whole;
// - the trace entry after the step, with its path.
//
// The verifier builds a state from those entries alone, runs the step and
// computes the root after it. The block is wrong when the step breaks a
// rule or its root differs from the trace; the proof is worthless when the
// step needs an entry the proof did not carry. A last kind shows a trace
// whose final entry is not the header's state root.
//
// Not covered: a producer who never publishes a block's transactions. A
// full node refuses such a block, but has nothing to show a light client.

import 'dart:typed_data';

import '../crypto/hex.dart';
import 'block.dart';
import 'merkle.dart';
import 'params.dart';
import 'smt.dart';
import 'state.dart';
import 'state_map.dart';
import 'tx.dart';

List<List<Object>> _path(List<ProofStep> p) => [
  for (final (h, right) in p) [toHex(h), right],
];

List<ProofStep> _pathOf(Object? j) => [for (final s in j as List) (fromHex((s as List)[0] as String), s[1] as bool)];

/// A block header as a light client keeps it: the block without its
/// transactions and trace, and the producer's signature.
class Header {
  Header(this.fields, this.sig);

  final Map<String, Object?> fields;
  final String sig;

  factory Header.of(Block b) => Header(b.header, b.sig);

  factory Header.fromJson(Map m) => Header((m['fields'] as Map).cast<String, Object?>(), m['sig'] as String);

  Map<String, Object?> toJson() => {'fields': fields, 'sig': sig};

  int get height => fields['height'] as int;
  String get prev => fields['prev'] as String;
  int get tick => fields['tick'] as int;
  String get producer => fields['producer'] as String;
  BigInt get target => BigInt.parse(fields['target'] as String, radix: 16);
  String get txRoot => fields['txRoot'] as String;
  int get txCount => fields['txCount'] as int;
  String get stateRoot => fields['stateRoot'] as String;
  String get traceRoot => fields['traceRoot'] as String;
  String get corpusRoot => fields['corpusRoot'] as String;
  Map<String, Object?> get proof => (fields['proof'] as Map).cast<String, Object?>();

  /// The block this header describes, without its transactions (a node
  /// that starts from a checkpoint knows its base by its header).
  Block get asBlock => _asBlock;

  Block get _asBlock => Block(
    height: height,
    prev: prev,
    tick: tick,
    producer: producer,
    txs: const [],
    txRoot: txRoot,
    stateRoot: stateRoot,
    corpusRoot: corpusRoot,
    proof: proof,
    sig: sig,
    target: target,
    traceRoot: traceRoot,
    trace: const [],
    headerTxCount: txCount,
  );

  /// The block hash (the header's, transactions are behind [txRoot]).
  String get hash => Block.hashOf(fields);

  bool get signed => Block.verifyHeader(fields, sig);
  BigInt get quality => _asBlock.quality;
}

/// Why a fraud proof does not hold.
class FraudError implements Exception {
  const FraudError(this.message);
  final String message;
  @override
  String toString() => message;
}

class FraudProof {
  FraudProof(this.json);

  final Map<String, Object?> json;

  Header get block => Header.fromJson(json['block'] as Map);

  /// The id of the block this proof shows wrong.
  String get blockHash => block.hash;

  /// Finds the first wrong step of [block] on top of [parent] (the state
  /// the block builds on, with its head set) and proves it; null when every
  /// step is right. [parentHeader] is null for the block after genesis.
  static Future<FraudProof?> build(ChainState parent, Header? parentHeader, Block block) async {
    final header = Header.of(block);
    final base = {'block': header.toJson(), if (parentHeader != null) 'parent': parentHeader.toJson()};
    final traceLeaves = [for (final r in block.trace) leafHash(fromHex(r))];
    if (block.trace.isEmpty || block.trace.last != block.stateRoot) {
      final last = block.txs.length;
      if (last < block.trace.length) {
        return FraudProof({
          ...base,
          'kind': 'end',
          'leaf': block.trace[last],
          'path': _path(merkleProof(traceLeaves, last)),
        });
      }
      return null; // a trace of the wrong length: nothing to show
    }
    var state = parent;
    // What the parent committed: its head as ''.
    final committedParent = parent.copy()..head = '';
    for (var step = 0; step <= block.txs.length; step++) {
      final committed = step == 0 ? committedParent : state;
      final pre = state.copy()..track();
      Object? broke;
      ChainState? post;
      try {
        if (step == 0) {
          if (block.target != pre.target) throw const ChainError('not the target of the chain');
          post = await Block.prelude(pre, block.tick, block.producer, block.proof);
        } else {
          post = pre.copy();
          await post.apply(block.txs[step - 1]);
        }
      } on ChainError catch (e) {
        broke = e;
      }
      final touched = pre.touched();
      final claimed = step < block.trace.length ? block.trace[step] : null;
      if (broke != null || post == null || claimed == null || post.rootHex != claimed) {
        if (claimed == null) return null;
        return FraudProof({
          ...base,
          'kind': 'step',
          'step': step,
          'preRoots': [for (final r in committed.namespaceRoots()) toHex(r)],
          if (step > 0) 'prePath': _path(merkleProof(traceLeaves, step - 1)),
          if (step > 0) 'tx': block.txs[step - 1].toJson(),
          if (step > 0) 'txPath': _path(merkleProof([for (final t in block.txs) leafHash(fromHex(t.id))], step - 1)),
          'postLeaf': claimed,
          'postPath': _path(merkleProof(traceLeaves, step)),
          'witness': _witness(committed, touched),
        });
      }
      state = post;
    }
    return null;
  }

  static Map<String, Object?> _witness(ChainState s, Map<String, Set<String>?> touched) {
    final out = <String, Object?>{
      'meta': {'full': s.entries('meta')},
    };
    for (final e in touched.entries) {
      final entries = s.entries(e.key);
      if (e.value == null) {
        out[e.key] = {'full': entries};
      } else {
        final tree = SmtTree(entries);
        out[e.key] = {
          'values': {for (final k in e.value!) k: entries[k]},
          'proofs': [for (final k in e.value!) tree.prove(k).toJson()],
        };
      }
    }
    return out;
  }

  /// Checks this proof with nothing but [params] and the headers it
  /// carries (which the caller matches against its own). Returns normally
  /// when the block is shown wrong; throws [FraudError] when the proof does
  /// not show it.
  Future<void> verify(ChainParams params, {required String genesisRoot}) async {
    final b = block;
    if (!b.signed) throw const FraudError('the block header is not signed by its producer');
    final steps = b.txCount + 1;
    Uint8List traceAt(int i, Object? path, String what) {
      final leaf = json[what] as String?;
      final root = leaf == null ? null : merkleClimb(leafHash(fromHex(leaf)), i, steps, _pathOf(path));
      if (root == null || toHex(root) != b.traceRoot) throw FraudError('trace entry $i is not in the block');
      return fromHex(leaf!);
    }

    switch (json['kind']) {
      case 'end':
        final root = merkleClimb(leafHash(fromHex(json['leaf'] as String)), b.txCount, steps, _pathOf(json['path']));
        if (root == null || toHex(root) != b.traceRoot) throw const FraudError('not the last trace entry');
        if (json['leaf'] == b.stateRoot) throw const FraudError('the trace ends at the state root');
        return;
      case 'step':
        break;
      default:
        throw const FraudError('unknown kind of proof');
    }
    final step = json['step'] as int;
    if (step < 0 || step >= steps) throw const FraudError('no such step');

    // The root before the step: the parent's state root for the prelude,
    // the trace entry before for a transaction.
    var preRoot = '';
    if (step == 0) {
      final parent = json['parent'] == null ? null : Header.fromJson(json['parent'] as Map);
      if (parent == null) {
        if (b.prev != '') throw const FraudError('the parent header is missing');
        preRoot = genesisRoot;
      } else {
        if (parent.hash != b.prev) throw const FraudError('not the block\'s parent');
        preRoot = parent.stateRoot;
      }
    }
    final preRoots = [for (final r in json['preRoots'] as List) fromHex(r as String)];
    if (preRoots.length != ChainState.namespaces.length) throw const FraudError('wrong number of namespaces');
    final preFromNamespaces = toHex(ChainState.stateRootOf(preRoots));
    if (step == 0) {
      if (preFromNamespaces != preRoot) throw const FraudError('the namespaces do not make the state before');
    } else {
      final climbed = merkleClimb(leafHash(fromHex(preFromNamespaces)), step - 1, steps, _pathOf(json['prePath']));
      if (climbed == null || toHex(climbed) != b.traceRoot) {
        throw const FraudError('the state before is not the trace entry before the step');
      }
    }

    // The state before, from the witnessed entries alone.
    final state = ChainState(params);
    final partials = <String, SmtPartial>{};
    final witness = (json['witness'] as Map? ?? const {}).cast<String, Object?>();
    for (var i = 0; i < ChainState.namespaces.length; i++) {
      final ns = ChainState.namespaces[i];
      final w = witness[ns] as Map?;
      if (ns == 'meta') {
        final full = (w?['full'] as Map?)?.cast<String, String>();
        if (full == null || toHex(smtRoot(full)) != toHex(preRoots[i])) throw const FraudError('meta is missing');
        state.putEncoded('meta', 'meta', full['meta']);
        continue;
      }
      if (w == null) {
        state.witness(ns, <String>{});
        continue;
      }
      if (w['full'] case final Map full) {
        final entries = full.cast<String, String>();
        if (toHex(smtRoot(entries)) != toHex(preRoots[i])) throw FraudError('the whole of $ns does not match');
        entries.forEach((k, v) => state.putEncoded(ns, k, v));
        continue;
      }
      final values = (w['values'] as Map).cast<String, String?>();
      final proofs = [for (final p in w['proofs'] as List) SmtProof.fromJson(p as Map)];
      final SmtPartial partial;
      try {
        partial = SmtPartial.fromProofs(preRoots[i], proofs);
        for (final e in values.entries) {
          final h = partial.valueHash(e.key);
          if ((h == null) != (e.value == null) || (h != null && toHex(h) != toHex(smtValueHash(e.value!)))) {
            throw FraudError('the value of $ns/${e.key} is not the proven one');
          }
        }
      } on SmtError catch (e) {
        throw FraudError('$e');
      }
      values.forEach((k, v) => state.putEncoded(ns, k, v));
      state.witness(ns, values.keys.toSet());
      partials[ns] = partial;
    }
    // A state commits its head as ''; the next block starts from it with
    // the head set to that block's hash.
    if (step == 0) state.head = b.prev;

    // Run the step.
    ChainState after;
    try {
      if (step == 0) {
        if (b.target != state.target) return; // the header lies about the target
        after = await Block.prelude(state, b.tick, b.producer, b.proof);
      } else {
        final tx = Tx.fromJson(json['tx'] as Map);
        final inBlock = merkleClimb(leafHash(fromHex(tx.id)), step - 1, b.txCount, _pathOf(json['txPath']));
        if (inBlock == null || toHex(inBlock) != b.txRoot) {
          throw const FraudError('the transaction is not in the block');
        }
        after = state.copy();
        await after.apply(tx);
      }
    } on ChainError {
      return; // the step breaks a rule: the block is wrong
    } on Unwitnessed catch (e) {
      throw FraudError('$e');
    }

    // The root after it.
    final postRoots = <Uint8List>[];
    for (var i = 0; i < ChainState.namespaces.length; i++) {
      final ns = ChainState.namespaces[i];
      final partial = partials[ns];
      if (ns == 'meta' || witness[ns] is Map && (witness[ns] as Map).containsKey('full')) {
        postRoots.add(smtRoot(after.entries(ns)));
      } else if (partial == null) {
        postRoots.add(preRoots[i]);
      } else {
        for (final k in (witness[ns] as Map)['values'].keys as Iterable) {
          partial.put(k as String, after.encoded(ns, k));
        }
        postRoots.add(partial.root);
      }
    }
    final post = toHex(ChainState.stateRootOf(postRoots));
    final claimed = traceAt(step, json['postPath'], 'postLeaf');
    if (post == toHex(claimed)) throw const FraudError('the step is right');
  }
}
