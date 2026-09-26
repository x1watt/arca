// The global chain's state (whitepaper, section 6): balances, circles with
// their pools and anchors, stewards' declared partitions, and totals.
// Nothing per file. The state is committed as one Merkle root over its
// entries in sorted order, so every node that applied the same blocks
// holds the same root.

import 'dart:convert';
import 'dart:typed_data';

import '../crypto/hex.dart';
import 'circle_log.dart' show governanceMessage, PayoutTable;
import '../crypto/schnorr.dart';
import 'merkle.dart';
import 'mining.dart';
import 'params.dart';
import 'passes.dart';
import 'rewards.dart';
import 'smt.dart';
import 'state_map.dart';
import 'tx.dart';

class CircleState {
  CircleState({required this.admin, required this.name, this.pool = 0, List<String>? moderators})
    : moderators = moderators ?? [];

  /// Replaced only by a majority of moderators; '' when there is none.
  String admin;
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

  /// Grains each member has claimed from the pool so far.
  final claimed = <String, int>{};

  /// Reading, as the latest anchor sets it: the price of a 24-hour pass
  /// (0 when passes are not sold), the free allowance in bytes per reader
  /// per day, and the sync score that gives members free access.
  int passPrice = 0;
  int freeAllowance = 0;
  int memberScore = 0;

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
    'claimed': claimed,
    'passPrice': passPrice,
    'freeAllowance': freeAllowance,
    'memberScore': memberScore,
  };

  factory CircleState.fromJson(Map m) =>
      CircleState(
          admin: m['admin'] as String,
          name: m['name'] as String,
          pool: m['pool'] as int,
          moderators: (m['moderators'] as List).cast<String>().toList(),
        )
        ..logHead = m['logHead'] as String
        ..dataRoot = m['dataRoot'] as String
        ..memberRoot = m['memberRoot'] as String
        ..payoutRoot = m['payoutRoot'] as String
        ..anchoredAt = m['anchoredAt'] as int
        ..claimed.addAll((m['claimed'] as Map).cast<String, int>())
        ..passPrice = m['passPrice'] as int
        ..freeAllowance = m['freeAllowance'] as int
        ..memberScore = m['memberScore'] as int;

  CircleState copy() => CircleState(admin: admin, name: name, pool: pool, moderators: [...moderators])
    ..logHead = logHead
    ..dataRoot = dataRoot
    ..memberRoot = memberRoot
    ..payoutRoot = payoutRoot
    ..anchoredAt = anchoredAt
    ..claimed.addAll(claimed)
    ..passPrice = passPrice
    ..freeAllowance = freeAllowance
    ..memberScore = memberScore;
}

/// A collection as the chain knows it: its circle, the partitions its
/// files are in, and a seed of interest (genesis corpora only).
class CollectionState {
  CollectionState({required this.circle, required List<int> partitions, this.seed = 0})
    : partitions = [...partitions]..sort();

  final String circle;
  final List<int> partitions;
  final int seed;

  Map<String, Object?> toJson() => {'circle': circle, 'partitions': partitions, 'seed': seed};

  factory CollectionState.fromJson(Map m) => CollectionState(
    circle: m['circle'] as String,
    partitions: (m['partitions'] as List).cast<int>(),
    seed: m['seed'] as int,
  );
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
  final balances = StateMap<int>('balances');
  final nonces = StateMap<int>('nonces');
  final circles = StateMap<CircleState>('circles');

  final collections = StateMap<CollectionState>('collections');

  /// Collection to (day to marcas burned for it by non-members).
  final burnsFor = StateMap<Map<int, int>>('burns');

  /// Steward key to standing, recomputed as each day closes.
  final standing = StateMap<int>('standing');

  /// Open passes by the id of the transaction that bought them.
  final passes = StateMap<PassState>('passes');

  /// Circle to (member key to sync score), updated as each day closes.
  final syncScores = StateMap<Map<String, int>>('sync');

  /// Steward key to (partition to the circle the keeping is for).
  final declarations = StateMap<Map<int, String>>('declarations');
  int height = 0;
  int tick = 0;
  String head = '';
  int burned = 0;
  int issued = 0;

  /// The corpus stewards prove against: its root and chunks per partition.
  /// Empty until set (then blocks need no mining proof, as at genesis).
  String corpusRoot = '';
  List<int> partitionSizes = [];

  /// Mining difficulty: a block's proof quality must be below it.
  BigInt target = maxTarget;

  /// The current day and its beacon (the last block of the day before),
  /// which picks each steward's slices for the day's holding proofs.
  int day = 0;
  String beacon = '';

  /// The tick of genesis: days count from here.
  int genesisTick = 0;

  /// How many stewards have declarations (kept so a block need not go
  /// through them all to know whether mining needs a proof).
  int stewards = 0;

  int dayOf(int tick) => tick < genesisTick ? 0 : (tick - genesisTick) ~/ params.dayTicks;

  /// Steward to (partition to the day it was declared), and to the day of
  /// its last holding proof.
  final declaredOn = StateMap<Map<int, int>>('declaredOn');
  final provenOn = StateMap<Map<int, int>>('provenOn');

  int balanceOf(String key) => balances[key] ?? 0;

  /// A testnet genesis: initial balances (a faucet) and the genesis circle.
  factory ChainState.genesis(
    ChainParams params, {
    Map<String, int> allocations = const {},
    Map<String, CircleState> circles = const {},
    Map<String, CollectionState> collections = const {},
    String corpusRoot = '',
    List<int> partitionSizes = const [],
    int genesisTick = 0,
  }) {
    final s = ChainState(params)
      ..genesisTick = genesisTick
      ..tick = genesisTick
      ..corpusRoot = corpusRoot
      ..partitionSizes = [...partitionSizes];
    s.balances.addAll(allocations);
    s.issued = allocations.values.fold(0, (a, b) => a + b);
    s.circles.addAll(circles);
    // Genesis counts as the first anchor of the genesis circles.
    for (final c in circles.values) {
      if (c.anchoredAt < 0) c.anchoredAt = genesisTick;
    }
    s.collections.addAll(collections);
    return s;
  }

  ChainState copy() {
    final s = ChainState(params)..meta = meta;
    balances.copyInto(s.balances, (v) => v);
    nonces.copyInto(s.nonces, (v) => v);
    circles.copyInto(s.circles, (v) => v.copy());
    collections.copyInto(s.collections, (v) => v); // never changed in place
    burnsFor.copyInto(s.burnsFor, Map.of);
    standing.copyInto(s.standing, (v) => v);
    passes.copyInto(s.passes, (v) => v.copy());
    syncScores.copyInto(s.syncScores, Map.of);
    declarations.copyInto(s.declarations, Map.of);
    declaredOn.copyInto(s.declaredOn, Map.of);
    provenOn.copyInto(s.provenOn, Map.of);
    return s;
  }

  // ---- The commitment: one sparse Merkle tree per namespace ----

  /// Namespaces in commitment order.
  static const namespaces = [
    'meta',
    'balances',
    'nonces',
    'circles',
    'collections',
    'burns',
    'standing',
    'passes',
    'sync',
    'declarations',
    'declaredOn',
    'provenOn',
  ];

  /// The scalar fields, as the one entry of the 'meta' namespace.
  Map<String, Object?> get meta => {
    'height': height,
    'tick': tick,
    'head': head,
    'burned': burned,
    'issued': issued,
    'corpusRoot': corpusRoot,
    'partitionSizes': partitionSizes,
    'target': target.toRadixString(16),
    'day': day,
    'beacon': beacon,
    'genesisTick': genesisTick,
    'stewards': stewards,
  };

  set meta(Map<String, Object?> m) {
    height = m['height'] as int;
    tick = m['tick'] as int;
    head = m['head'] as String;
    burned = m['burned'] as int;
    issued = m['issued'] as int;
    corpusRoot = m['corpusRoot'] as String;
    partitionSizes = (m['partitionSizes'] as List).cast<int>().toList();
    target = BigInt.parse(m['target'] as String, radix: 16);
    day = m['day'] as int;
    beacon = m['beacon'] as String;
    genesisTick = m['genesisTick'] as int;
    stewards = m['stewards'] as int;
  }

  static String _intMap(Map<int, Object?> m) => canonicalJson({for (final e in m.entries) '${e.key}': e.value});
  static Map<int, V> _intMapOf<V>(String v) => {
    for (final e in (jsonDecode(v) as Map).entries) int.parse(e.key as String): e.value as V,
  };

  /// Every map with its encoder and decoder, by namespace.
  List<(StateMap, String Function(Object?), Object Function(String))> get _maps => [
    (balances, (v) => '$v', int.parse),
    (nonces, (v) => '$v', int.parse),
    (circles, (v) => canonicalJson((v as CircleState).toJson()), (v) => CircleState.fromJson(jsonDecode(v) as Map)),
    (
      collections,
      (v) => canonicalJson((v as CollectionState).toJson()),
      (v) => CollectionState.fromJson(jsonDecode(v) as Map),
    ),
    (burnsFor, (v) => _intMap(v as Map<int, int>), _intMapOf<int>),
    (standing, (v) => '$v', int.parse),
    (passes, (v) => canonicalJson((v as PassState).toJson()), (v) => PassState.fromJson(jsonDecode(v) as Map)),
    (syncScores, canonicalJson, (v) => (jsonDecode(v) as Map).cast<String, int>()),
    (declarations, (v) => _intMap(v as Map<int, String>), _intMapOf<String>),
    (declaredOn, (v) => _intMap(v as Map<int, int>), _intMapOf<int>),
    (provenOn, (v) => _intMap(v as Map<int, int>), _intMapOf<int>),
  ];

  StateMap mapOf(String namespace) => _maps.firstWhere((m) => m.$1.namespace == namespace).$1;

  /// The encoded value of [key] in [namespace], or null when absent.
  String? encoded(String namespace, String key) {
    if (namespace == 'meta') return canonicalJson(meta);
    final (map, encode, _) = _maps.firstWhere((m) => m.$1.namespace == namespace);
    final v = map.raw[key];
    return v == null ? null : encode(v);
  }

  /// All entries of [namespace], encoded.
  Map<String, String> entries(String namespace) {
    if (namespace == 'meta') return {'meta': canonicalJson(meta)};
    final (map, encode, _) = _maps.firstWhere((m) => m.$1.namespace == namespace);
    return {for (final e in map.raw.entries) e.key: encode(e.value)};
  }

  /// Sets [key] of [namespace] from its encoded [value] (null removes).
  void putEncoded(String namespace, String key, String? value) {
    if (namespace == 'meta') {
      meta = jsonDecode(value!) as Map<String, Object?>;
      return;
    }
    final (map, _, decode) = _maps.firstWhere((m) => m.$1.namespace == namespace);
    if (value == null) {
      map.raw.remove(key);
    } else {
      map.raw[key] = decode(value);
    }
  }

  /// A state from all its entries (a snapshot).
  factory ChainState.fromEntries(ChainParams params, Map<String, Map<String, String>> entries) {
    final s = ChainState(params);
    for (final ns in namespaces) {
      entries[ns]?.forEach((k, v) => s.putEncoded(ns, k, v));
    }
    return s;
  }

  /// Every namespace's root, in [namespaces] order.
  List<Uint8List> namespaceRoots() => [
    smtRoot({'meta': canonicalJson(meta)}),
    for (final (map, encode, _) in _maps) map.root(encode),
  ];

  /// Starts recording which entries the next step touches.
  void track() {
    for (final m in _maps) {
      m.$1.track();
    }
  }

  /// What the tracked step touched: namespace to keys, or to null when it
  /// went through the whole namespace.
  Map<String, Set<String>?> touched() {
    final out = <String, Set<String>?>{};
    for (final (map, _, _) in _maps) {
      final t = map.touched;
      if (t == null) continue;
      if (t.all) {
        out[map.namespace] = null;
      } else if (t.keys.isNotEmpty) {
        out[map.namespace] = t.keys;
      }
      map.touched = null;
    }
    return out;
  }

  /// Limits [namespace] to [keys] (a verifier's partial state).
  void witness(String namespace, Set<String> keys) => mapOf(namespace).witnessed = keys;

  /// Applies [tx] or throws [ChainError] and leaves the state as it was
  /// only if the caller works on a copy (blocks do).
  Future<void> apply(Tx tx) async {
    if (!tx.verify()) throw const ChainError('bad signature');
    final numbered = TxType.numbered(tx.type);
    final expected = numbered ? nonces[tx.from] ?? 0 : 0;
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
        final id = b['circle'] as String? ?? '';
        final circle = circles[id];
        if (circle == null) throw const ChainError('no such circle');
        if (!circle.mayAnchor(tx.from)) throw const ChainError('only the admin or a moderator anchors');
        _governance(id, circle, tx, b);
        for (final root in ['logHead', 'dataRoot', 'memberRoot', 'payoutRoot']) {
          final v = b[root] as String? ?? '';
          if (v.isNotEmpty && !RegExp(r'^[0-9a-f]{64}$').hasMatch(v)) throw ChainError('bad $root');
        }
        circle
          ..logHead = b['logHead'] as String? ?? ''
          ..dataRoot = b['dataRoot'] as String? ?? ''
          ..memberRoot = b['memberRoot'] as String? ?? ''
          ..payoutRoot = b['payoutRoot'] as String? ?? ''
          ..anchoredAt = tick;
        if (b['collections'] case final Map listed) _listCollections(id, listed);
        if (b['reading'] case final Map r) {
          int field(String name) {
            final v = r[name] ?? 0;
            if (v is! int || v < 0) throw ChainError('bad $name');
            return v;
          }

          circle
            ..passPrice = field('passPrice')
            ..freeAllowance = field('freeAllowance')
            ..memberScore = field('memberScore');
        }
      case TxType.claim:
        final id = b['circle'] as String? ?? '';
        final circle = circles[id];
        if (circle == null) throw const ChainError('no such circle');
        final total = b['total'] as int? ?? 0;
        final List<ProofStep> path;
        try {
          path = [for (final step in b['path'] as List) (fromHex((step as List)[0] as String), step[1] as bool)];
        } catch (_) {
          throw const ChainError('bad proof');
        }
        final leaf = PayoutTable.leaf(id, tx.from, total);
        if (circle.payoutRoot.isEmpty ||
            !merkleVerifyAt(
              leaf,
              b['index'] as int? ?? -1,
              b['count'] as int? ?? 0,
              path,
              fromHex(circle.payoutRoot),
            )) {
          throw const ChainError('not in the circle\'s payout table');
        }
        final owed = total - (circle.claimed[tx.from] ?? 0);
        if (owed <= 0) throw const ChainError('nothing left to claim');
        if (circle.pool < owed) throw ChainError('the pool holds ${circle.pool}, the claim is $owed');
        circle.pool -= owed;
        circle.claimed[tx.from] = total;
        balances[tx.from] = balanceOf(tx.from) + owed;
      case TxType.declare:
        final circle = b['circle'] as String? ?? '';
        if (!circles.containsKey(circle)) throw const ChainError('no such circle');
        final parts = (b['partitions'] as List? ?? const []).cast<int>();
        if (parts.isEmpty || parts.any((p) => p < 0)) throw const ChainError('bad partitions');
        if (partitionSizes.isNotEmpty && parts.any((p) => p >= partitionSizes.length)) {
          throw const ChainError('no such partition');
        }
        if (!declarations.containsKey(tx.from)) stewards++;
        final mine = declarations.putIfAbsent(tx.from, () => {});
        final since = declaredOn.putIfAbsent(tx.from, () => {});
        for (final p in parts) {
          mine[p] = circle;
          since[p] = day;
        }
      case TxType.undeclare:
        final parts = (b['partitions'] as List? ?? const []).cast<int>();
        final mine = declarations[tx.from];
        for (final p in parts) {
          mine?.remove(p);
          declaredOn[tx.from]?.remove(p);
        }
        if (mine != null && mine.isEmpty) {
          stewards--;
          declarations.remove(tx.from);
          declaredOn.remove(tx.from);
        }
      case TxType.burn:
        final amount = b['amount'] as int? ?? 0;
        if (amount <= 0) throw const ChainError('amount must be positive');
        final id = b['collection'] as String?;
        if (id != null && !collections.containsKey(id)) throw const ChainError('no such collection');
        _spend(tx.from, amount);
        burned += amount;
        burnedFor(tx.from, id ?? '', amount);
      case TxType.buyPass:
        final id = b['circle'] as String? ?? '';
        final circle = circles[id];
        if (circle == null) throw const ChainError('no such circle');
        if (!isLive(id, tick)) throw const ChainError('the circle is cut off from the chain: no passes are sold');
        if (circle.passPrice <= 0) throw const ChainError('this circle does not sell passes');
        final collection = b['collection'] as String? ?? '';
        if (collection.isNotEmpty && collections[collection]?.circle != id) {
          throw const ChainError('no such collection in this circle');
        }
        _spend(tx.from, circle.passPrice);
        passes[tx.id] = PassState(
          reader: tx.from,
          circle: id,
          collection: collection,
          price: circle.passPrice,
          expires: tick + params.passTicks,
        );
      case TxType.settlePass:
        final id = b['pass'] as String? ?? '';
        final pass = passes[id];
        if (pass == null) throw const ChainError('no such pass, or it is closed');
        if (pass.activeAt(tick)) throw const ChainError('the pass is still active');
        if (pass.delivered.containsKey(tx.from)) throw const ChainError('this server settled already');
        final receipt = Receipt(
          pass: id,
          server: tx.from,
          bytes: b['bytes'] as int? ?? 0,
          sig: b['sig'] as String? ?? '',
        );
        if (receipt.bytes <= 0 || !receipt.verify(pass.reader)) {
          throw const ChainError('not a receipt the reader signed');
        }
        pass.delivered[tx.from] = receipt.bytes;
      case TxType.holdingProof:
        final proof = SliceProof.fromJson(b['proof'] as Map);
        if (proof.steward != tx.from) throw const ChainError('a steward proves only its own keeping');
        if (declarations[tx.from]?[proof.partition] != proof.circle) throw const ChainError('partition not declared');
        if ((b['day'] as int?) != day) throw const ChainError('a holding proof is for the current day');
        final why = await proof.check(
          params,
          holdChallenge(beacon, day, tx.from, proof.partition),
          corpusRoot,
          partitionSizes,
        );
        if (why != null) throw ChainError('bad holding proof: $why');
        provenOn.putIfAbsent(tx.from, () => {})[proof.partition] = day;
      default:
        throw ChainError('unknown transaction ${tx.type}');
    }
    if (numbered) nonces[tx.from] = expected + 1;
  }

  /// Closes the current day and opens [newDay]: every steward must have
  /// proven each partition it declared before the day began, or loses all
  /// its declarations (whitepaper, section 7).
  void startDay(int newDay) {
    if (newDay <= day) return;
    for (final steward in declarations.keys.toList()) {
      final since = declaredOn[steward] ?? const {};
      final proven = provenOn[steward] ?? const {};
      final missed = declarations[steward]!.keys.any((p) => (since[p] ?? day) < day && proven[p] != day);
      if (missed) {
        stewards--;
        declarations.remove(steward);
        declaredOn.remove(steward);
        provenOn.remove(steward);
        standing.remove(steward);
        for (final scores in syncScores.values) {
          scores.remove(steward);
        }
      }
    }
    settleDay(this, day);
    closePasses(this, genesisTick + newDay * params.dayTicks);
    day = newDay;
    beacon = head;
  }

  /// Admin and moderator changes an anchor carries (rules 2 and 6 of the
  /// whitepaper's section 4): the admin appoints moderators; removing one or
  /// replacing the admin takes a majority of the current moderators, who
  /// sign [governanceMessage] over the new admin and moderators.
  void _governance(String id, CircleState circle, Tx tx, Map<String, Object?> b) {
    if (!b.containsKey('admin') && !b.containsKey('moderators')) return;
    final admin = b.containsKey('admin') ? b['admin'] as String? ?? '' : circle.admin;
    final mods = b.containsKey('moderators')
        ? (b['moderators'] as List? ?? const []).cast<String>().toSet().toList()
        : [...circle.moderators];
    final key = RegExp(r'^[0-9a-f]{64}$');
    if ((admin.isNotEmpty && !key.hasMatch(admin)) || mods.any((m) => !key.hasMatch(m))) {
      throw const ChainError('bad key');
    }
    if (mods.length > 64) throw const ChainError('at most 64 moderators');
    final removes = circle.moderators.any((m) => !mods.contains(m));
    if (admin != circle.admin || removes) {
      final msg = governanceMessage(id, admin, mods);
      final approvals = (b['approvals'] as Map? ?? const {}).cast<String, String>();
      var agree = 0;
      for (final m in circle.moderators) {
        final sig = approvals[m];
        try {
          if (sig != null && schnorrVerify(fromHex(m), msg, fromHex(sig))) agree++;
        } catch (_) {}
      }
      if (agree * 2 <= circle.moderators.length) {
        throw ChainError('needs a majority of the ${circle.moderators.length} moderators, has $agree');
      }
    } else if (mods.length != circle.moderators.length && tx.from != circle.admin) {
      throw const ChainError('only the admin appoints moderators');
    }
    circle
      ..admin = admin
      ..moderators.clear()
      ..moderators.addAll(mods);
  }

  /// The circle's public collections as its anchor lists them, replacing
  /// the ones it listed before. Seeds stay with their collections.
  void _listCollections(String circle, Map listed) {
    if (listed.length > 256) throw const ChainError('at most 256 collections per anchor');
    final next = <String, CollectionState>{};
    for (final e in listed.entries) {
      final id = '${e.key}';
      if (!RegExp(r'^[a-z0-9][a-z0-9-]{2,62}$').hasMatch(id)) throw const ChainError('bad collection id');
      final existing = collections[id];
      if (existing != null && existing.circle != circle) throw const ChainError('collection of another circle');
      final parts = (e.value as List? ?? const []).cast<int>().toSet().toList();
      if (parts.any((p) => p < 0 || partitionSizes.isNotEmpty && p >= partitionSizes.length)) {
        throw const ChainError('no such partition');
      }
      next[id] = CollectionState(circle: circle, partitions: parts, seed: existing?.seed ?? 0);
    }
    collections
      ..removeWhere((_, c) => c.circle == circle)
      ..addAll(next);
  }

  /// Whether [circle] anchored recently enough at [atTick] to earn.
  bool isLive(String circle, int atTick) {
    final c = circles[circle];
    return c != null && c.anchoredAt >= 0 && atTick - c.anchoredAt <= params.anchorLifeTicks;
  }

  /// Records marcas [key] burned for [collection]: they raise its interest
  /// for 30 days, unless [key] is a member of its circle.
  void burnedFor(String key, String collection, int amount) {
    final c = collections[collection];
    if (c == null || amount <= 0 || _isMember(key, c.circle)) return;
    final days = burnsFor.putIfAbsent(collection, () => {});
    days[day] = (days[day] ?? 0) + amount;
  }

  /// Whether [key] belongs to [circle]: its admin, a moderator, or a
  /// steward keeping partitions for it. Burns by members do not raise the
  /// interest of their own circle's collections.
  bool _isMember(String key, String circle) {
    final c = circles[circle];
    if (c != null && c.mayAnchor(key)) return true;
    return declarations[key]?.values.contains(circle) ?? false;
  }

  void _spend(String from, int amount) {
    final have = balanceOf(from);
    if (have < amount) throw ChainError('balance $have, needs $amount');
    balances[from] = have - amount;
    if (balances[from] == 0) balances.remove(from);
  }

  /// The state root: the Merkle root over the namespaces' roots.
  Uint8List root() => stateRootOf(namespaceRoots());

  static Uint8List stateRootOf(List<Uint8List> namespaceRoots) =>
      merkleRoot([for (final r in namespaceRoots) leafHash(r)]);

  String get rootHex => toHex(root());
}
