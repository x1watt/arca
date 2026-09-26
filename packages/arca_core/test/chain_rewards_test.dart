// A day's issuance (whitepaper, section 8): the storage and interest
// budgets, the replication curve, standing and its 1.5x cap. Keeping is set
// straight into the state (as if every holding proof had been posted), so
// these tests run the settlement rules alone.
import 'package:arca_core/arca_core.dart';
import 'package:arca_core/src/chain/params.dart';
import 'package:arca_core/src/chain/rewards.dart';
import 'package:arca_core/src/chain/state.dart';
import 'package:arca_core/src/chain/tx.dart';
import 'package:test/test.dart';

const p = ChainParams.testnet;
const m = ChainParams.grainsPerMarca;

/// Steward names stand in for keys: settlement never checks signatures.
ChainState library({
  required List<String> circles,
  required List<int> partitionSizes,
  Map<String, CollectionState> collections = const {},
}) => ChainState.genesis(
  p,
  circles: {for (final c in circles) c: CircleState(admin: 'admin-$c', name: c)},
  collections: collections,
  partitionSizes: partitionSizes,
  corpusRoot: 'x',
);

/// [steward] keeps [partitions] for [circle] from day 0 on.
void keep(ChainState s, String steward, String circle, List<int> partitions) {
  for (final q in partitions) {
    (s.declarations[steward] ??= {})[q] = circle;
    (s.declaredOn[steward] ??= {})[q] = 0;
  }
}

/// Everyone proves everything today; every circle anchored in time unless
/// listed in [lapsed]; the day closes.
void proveAndClose(ChainState s, {Set<String> lapsed = const {}}) {
  for (final e in s.circles.entries) {
    if (!lapsed.contains(e.key)) e.value.anchoredAt = s.genesisTick + (s.day + 1) * p.dayTicks - 1;
  }
  for (final e in s.declarations.entries) {
    for (final q in e.value.keys) {
      (s.provenOn[e.key] ??= {})[q] = s.day;
    }
  }
  s.startDay(s.day + 1);
}

int pool(ChainState s, String circle) => s.circles[circle]!.pool;

void main() {
  test('the replication curve: each copy earns more up to ten copies, then the total is frozen', () {
    final perCopy = [for (var n = 1; n <= 15; n++) curveShare(BigInt.from(1000000), n).toInt()];
    for (var n = 1; n < 10; n++) {
      expect(perCopy[n], greaterThan(perCopy[n - 1]), reason: 'copy ${n + 1} earns more each than copy $n');
    }
    for (var n = 10; n < 15; n++) {
      expect(perCopy[n], lessThan(perCopy[n - 1]), reason: 'beyond ten, every copy takes from all');
      expect(perCopy[n] * (n + 1), closeTo(1000000, n + 1), reason: 'the total stays at ten copies\' worth');
    }
    expect(perCopy[0], 10000, reason: 'a lone copy earns a hundredth of the full amount');
  });

  test('storage budget: by size and copies; a lone copy earns little; nothing unearned is created', () {
    final s = library(circles: ['x', 'y'], partitionSizes: [256, 256, 128]);
    keep(s, 'a', 'x', [0]); // alone on partition 0
    keep(s, 'b', 'y', [1]);
    keep(s, 'c', 'y', [1]); // two copies of partition 1; partition 2 unkept
    final budget = p.issuanceOn(0) * ChainParams.storageShare ~/ 100;
    proveAndClose(s);
    // Weights: 256 x 1 for partition 0, 256 x 4 for partition 1.
    expect(pool(s, 'x'), budget * 1 ~/ 5);
    expect(pool(s, 'y'), closeTo(budget * 4 ~/ 5, 2));
    expect(s.issued, pool(s, 'x') + pool(s, 'y'), reason: 'no collections: the interest budget is not created');
  });

  test('interest: seeded collections pay, a circle keeping only its own archive earns storage only', () {
    final s = library(
      circles: ['wiki', 'x', 'junk'],
      partitionSizes: [256, 256],
      collections: {
        'wikipedia': CollectionState(circle: 'wiki', partitions: [0], seed: 1000 * m),
        'my-junk': CollectionState(circle: 'junk', partitions: [1]),
      },
    );
    keep(s, 'a', 'x', [0]);
    keep(s, 'j', 'junk', [1]);
    proveAndClose(s);
    final storage = p.issuanceOn(0) * ChainParams.storageShare ~/ 100;
    final interest = p.issuanceOn(0) * ChainParams.interestShare ~/ 100;
    expect(pool(s, 'junk'), closeTo(storage ~/ 2, 1), reason: 'storage only');
    expect(pool(s, 'x'), closeTo(storage ~/ 2 + interest, 2), reason: 'storage and all the interest');
    expect(s.standing.keys, ['a']);
  });

  test('burns: only non-members raise interest, and only for 30 days; members burning gain nothing', () async {
    final alice = generateSecretKey(), admin = generateSecretKey();
    final s = ChainState.genesis(
      p,
      allocations: {toHex(publicKeyOf(alice)): 100 * m, toHex(publicKeyOf(admin)): 100 * m},
      circles: {'radio': CircleState(admin: toHex(publicKeyOf(admin)), name: 'Radio')},
      collections: {
        'tapes': CollectionState(circle: 'radio', partitions: [0]),
      },
      partitionSizes: [256],
    );
    await s.apply(Tx.sign(admin, TxType.burn, 0, {'amount': 5 * m, 'collection': 'tapes'}));
    expect(s.burnsFor, isEmpty, reason: 'the admin is a member');
    await s.apply(Tx.sign(alice, TxType.burn, 0, {'amount': 7 * m, 'collection': 'tapes'}));
    expect(s.burnsFor['tapes'], {0: 7 * m});
    expect(s.burned, 12 * m);
    await expectLater(
      s.apply(Tx.sign(alice, TxType.burn, 1, {'amount': 1, 'collection': 'nope'})),
      throwsA(isA<ChainError>()),
    );
    // A keeper earns interest while the burn is in the window.
    keep(s, 'k', 'radio', [0]);
    for (var d = 0; d < ChainParams.interestWindowDays; d++) {
      proveAndClose(s);
      expect(s.standing['k'], isNotNull, reason: 'day $d is inside the window');
    }
    proveAndClose(s);
    expect(s.standing['k'], isNull, reason: 'after 30 days the burn no longer counts');
    expect(s.burnsFor, isEmpty);
  });

  test('a circle that stopped anchoring earns nothing, and its collections earn no interest', () {
    final s = library(
      circles: ['wiki', 'x'],
      partitionSizes: [256, 256],
      collections: {
        'wikipedia': CollectionState(circle: 'wiki', partitions: [0], seed: 1000 * m),
      },
    );
    keep(s, 'a', 'x', [0]); // keeps Wikipedia for x
    keep(s, 'b', 'wiki', [1]);
    proveAndClose(s); // day 0: both live
    final x0 = pool(s, 'x'), wiki0 = pool(s, 'wiki');
    expect(x0, greaterThan(0));
    proveAndClose(s, lapsed: {'x'}); // day 1: x missed its anchors
    expect(pool(s, 'x'), x0, reason: 'x is cut off');
    expect(pool(s, 'wiki'), greaterThan(wiki0));
    final wiki1 = pool(s, 'wiki');
    proveAndClose(s, lapsed: {'wiki'}); // day 2: x is back, wiki is cut off
    expect(pool(s, 'wiki'), wiki1, reason: 'wiki is cut off now');
    expect(s.standing, isEmpty, reason: 'a cut-off circle\'s collections earn no interest');
    expect(pool(s, 'x'), x0 + p.issuanceOn(2) * ChainParams.storageShare ~/ 100 ~/ 2, reason: 'x earns storage again');
  });

  test('a steward that misses a proof loses its standing', () {
    final s = library(
      circles: ['wiki', 'x'],
      partitionSizes: [256],
      collections: {
        'wikipedia': CollectionState(circle: 'wiki', partitions: [0], seed: 1000 * m),
      },
    );
    keep(s, 'a', 'x', [0]);
    proveAndClose(s);
    proveAndClose(s);
    expect(s.standing['a'], isNotNull);
    s.startDay(s.day + 1); // no proof today
    expect(s.standing['a'], isNull);
    expect(s.declarations['a'], isNull);
  });

  for (final ringSize in [2, 5]) {
    test('$ringSize circles keeping each other\'s junk earn under 1.5 times what honest stewards earn', () {
      // Ten honest stewards keep Wikipedia only. In each ring circle, ten
      // stewards keep Wikipedia, their own junk and every other ring
      // circle's junk, to pass standing around.
      final ring = [for (var i = 0; i < ringSize; i++) 'r$i'];
      final s = library(
        circles: ['wiki', 'honest', ...ring],
        partitionSizes: [for (var i = 0; i <= ringSize; i++) 256],
        collections: {
          'wikipedia': CollectionState(circle: 'wiki', partitions: [0], seed: 1000 * m),
          for (var i = 0; i < ringSize; i++) '${ring[i]}-junk': CollectionState(circle: ring[i], partitions: [i + 1]),
        },
      );
      for (var k = 0; k < 10; k++) {
        keep(s, 'honest$k', 'honest', [0]);
        for (final c in ring) {
          keep(s, '$c-$k', c, [for (var i = 0; i <= ringSize; i++) i]);
        }
      }
      for (var d = 0; d < 60; d++) {
        proveAndClose(s);
      }
      final honest = s.standing['honest0']!, colluder = s.standing['r0-0']!;
      print('ring of $ringSize: ${(colluder / honest).toStringAsFixed(3)}x an honest steward\'s standing');
      expect(colluder, greaterThan(honest), reason: 'keeping others\' data does pass standing on');
      expect(colluder / honest, lessThanOrEqualTo(1.5));
    });
  }
}
