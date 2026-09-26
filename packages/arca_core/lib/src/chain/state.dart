// The global chain's state (whitepaper, section 6): balances, circles with
// their pools and anchors, stewards' declared partitions, and totals.
// Nothing per file. The state is committed as one Merkle root over its
// entries in sorted order, so every node that applied the same blocks
// holds the same root.

import 'dart:convert';
import 'dart:typed_data';

import '../crypto/hex.dart';
import 'merkle.dart';
import 'params.dart';
import 'tx.dart';

class CircleState {
  CircleState({required this.admin, required this.name, this.pool = 0, List<String>? moderators})
    : moderators = moderators ?? [];

  final String admin;
  final String name;
  final List<String> moderators;

  /// Marcas earned by the circle's stewards, waiting to be claimed.
  int pool;

  /// The latest anchor (section 4): roots of the circle's log, public data,
  /// members and payout table, and when it was posted.
  String logHead = '';
  String dataRoot = '';
  String memberRoot = '';
  String payoutRoot = '';
  int anchoredAt = -1;

  bool mayAnchor(String key) => key == admin || moderators.contains(key);

  Map<String, Object?> toJson() => {
    'admin': admin,
    'name': name,
    'moderators': moderators,
    'pool': pool,
    'logHead': logHead,
    'dataRoot': dataRoot,
    'memberRoot': memberRoot,
    'payoutRoot': payoutRoot,
    'anchoredAt': anchoredAt,
  };

  CircleState copy() => CircleState(admin: admin, name: name, pool: pool, moderators: [...moderators])
    ..logHead = logHead
    ..dataRoot = dataRoot
    ..memberRoot = memberRoot
    ..payoutRoot = payoutRoot
    ..anchoredAt = anchoredAt;
}

/// A rejected transaction or block, with the rule it broke.
class ChainError implements Exception {
  const ChainError(this.message);
  final String message;
  @override
  String toString() => message;
}

class ChainState {
  ChainState(this.params);

  final ChainParams params;
  final balances = <String, int>{};
  final nonces = <String, int>{};
  final circles = <String, CircleState>{};

  /// Steward key to (partition to the circle the keeping is for).
  final declarations = <String, Map<int, String>>{};
  int height = 0;
  int tick = 0;
  String head = '';
  int burned = 0;
  int issued = 0;

  int balanceOf(String key) => balances[key] ?? 0;

  /// A testnet genesis: initial balances (a faucet) and the genesis circle.
  factory ChainState.genesis(
    ChainParams params, {
    Map<String, int> allocations = const {},
    Map<String, CircleState> circles = const {},
  }) {
    final s = ChainState(params);
    s.balances.addAll(allocations);
    s.issued = allocations.values.fold(0, (a, b) => a + b);
    s.circles.addAll(circles);
    return s;
  }

  ChainState copy() {
    final s = ChainState(params)
      ..height = height
      ..tick = tick
      ..head = head
      ..burned = burned
      ..issued = issued;
    s.balances.addAll(balances);
    s.nonces.addAll(nonces);
    circles.forEach((k, v) => s.circles[k] = v.copy());
    declarations.forEach((k, v) => s.declarations[k] = Map.of(v));
    return s;
  }

  /// Applies [tx] or throws [ChainError] and leaves the state as it was
  /// only if the caller works on a copy (blocks do).
  void apply(Tx tx) {
    if (!tx.verify()) throw const ChainError('bad signature');
    final expected = nonces[tx.from] ?? 0;
    if (tx.nonce != expected) throw ChainError('nonce ${tx.nonce}, expected $expected');
    final b = tx.body;
    switch (tx.type) {
      case TxType.transfer:
        final to = b['to'] as String? ?? '';
        final amount = b['amount'] as int? ?? 0;
        if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(to)) throw const ChainError('bad recipient');
        if (amount <= 0) throw const ChainError('amount must be positive');
        _spend(tx.from, amount);
        balances[to] = balanceOf(to) + amount;
      case TxType.createCircle:
        final id = b['circle'] as String? ?? '';
        if (!RegExp(r'^[a-z0-9][a-z0-9-]{2,62}$').hasMatch(id)) throw const ChainError('bad circle id');
        if (circles.containsKey(id)) throw const ChainError('circle exists');
        _spend(tx.from, params.circleFee);
        burned += params.circleFee;
        circles[id] = CircleState(admin: tx.from, name: (b['name'] as String? ?? id).trim());
      case TxType.anchor:
        final circle = circles[b['circle']];
        if (circle == null) throw const ChainError('no such circle');
        if (!circle.mayAnchor(tx.from)) throw const ChainError('only the admin or a moderator anchors');
        circle
          ..logHead = b['logHead'] as String? ?? ''
          ..dataRoot = b['dataRoot'] as String? ?? ''
          ..memberRoot = b['memberRoot'] as String? ?? ''
          ..payoutRoot = b['payoutRoot'] as String? ?? ''
          ..anchoredAt = tick;
        if (b['moderators'] case final List mods) {
          if (tx.from != circle.admin) throw const ChainError('only the admin sets moderators');
          circle.moderators
            ..clear()
            ..addAll(mods.cast<String>());
        }
      case TxType.declare:
        final circle = b['circle'] as String? ?? '';
        if (!circles.containsKey(circle)) throw const ChainError('no such circle');
        final parts = (b['partitions'] as List? ?? const []).cast<int>();
        if (parts.isEmpty || parts.any((p) => p < 0)) throw const ChainError('bad partitions');
        final mine = declarations.putIfAbsent(tx.from, () => {});
        for (final p in parts) {
          mine[p] = circle;
        }
      case TxType.undeclare:
        final parts = (b['partitions'] as List? ?? const []).cast<int>();
        final mine = declarations[tx.from];
        for (final p in parts) {
          mine?.remove(p);
        }
        if (mine != null && mine.isEmpty) declarations.remove(tx.from);
      default:
        throw ChainError('unknown transaction ${tx.type}');
    }
    nonces[tx.from] = expected + 1;
  }

  void _spend(String from, int amount) {
    final have = balanceOf(from);
    if (have < amount) throw ChainError('balance $have, needs $amount');
    balances[from] = have - amount;
    if (balances[from] == 0) balances.remove(from);
  }

  /// The state root: every entry, sorted, as a leaf.
  Uint8List root() {
    final entries = <String>[
      for (final k in (balances.keys.toList()..sort())) 'b:$k:${balances[k]}',
      for (final k in (nonces.keys.toList()..sort())) 'n:$k:${nonces[k]}',
      for (final k in (circles.keys.toList()..sort())) 'c:$k:${canonicalJson(circles[k]!.toJson())}',
      for (final k in (declarations.keys.toList()..sort()))
        'd:$k:${canonicalJson({for (final e in declarations[k]!.entries) '${e.key}': e.value})}',
      't:$height:$tick:$burned:$issued',
    ];
    return merkleRoot([for (final e in entries) leafHash(utf8.encode(e))]);
  }

  String get rootHex => toHex(root());
}
