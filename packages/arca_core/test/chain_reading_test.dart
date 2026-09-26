// Reading on the chain (whitepaper, sections 8 and 9): passes bought at
// the circle's price, settled by servers with the reader's signed byte
// totals, half burned and half to servers; and sync scores.
import 'package:arca_core/arca_core.dart';
import 'package:arca_core/src/chain/params.dart';
import 'package:arca_core/src/chain/passes.dart';
import 'package:arca_core/src/chain/state.dart';
import 'package:arca_core/src/chain/tx.dart';
import 'package:test/test.dart';

import 'chain_rewards_test.dart' show keep, proveAndClose, library;

const p = ChainParams.testnet;
const m = ChainParams.grainsPerMarca;
String pk(List<int> k) => toHex(publicKeyOf(k));
Matcher throwsRule(String text) => throwsA(predicate((e) => '$e'.contains(text), 'error containing "$text"'));

void main() {
  final admin = generateSecretKey(), reader = generateSecretKey();
  final s1 = generateSecretKey(), s2 = generateSecretKey();

  Future<ChainState> circleSellingPasses({int price = 10 * m}) async {
    final s = ChainState.genesis(
      p,
      allocations: {pk(reader): 100 * m, pk(admin): 100 * m},
      circles: {'radio': CircleState(admin: pk(admin), name: 'Radio')},
      collections: {
        'tapes': CollectionState(circle: 'radio', partitions: [0]),
      },
      partitionSizes: [256],
    );
    await s.apply(
      Tx.sign(admin, TxType.anchor, 0, {
        'circle': 'radio',
        'reading': {'passPrice': price, 'freeAllowance': 1 << 20, 'memberScore': 100},
      }),
    );
    return s;
  }

  test('a pass: bought at the circle\'s price, settled by servers after it ends, half burned, half by bytes', () async {
    final s = await circleSellingPasses();
    final buy = Tx.sign(reader, TxType.buyPass, 0, {'circle': 'radio', 'collection': 'tapes'});
    await s.apply(buy);
    expect(s.balanceOf(pk(reader)), 90 * m);
    final pass = buy.id;
    final r1 = Receipt.sign(reader, pass, pk(s1), 3000);
    await expectLater(s.apply(Tx.sign(s1, TxType.settlePass, 0, r1.settleBody())), throwsRule('still active'));

    s.tick += p.passTicks;
    // A receipt the reader did not sign, or signed for someone else, fails.
    final forged = Receipt.sign(s1, pass, pk(s1), 1 << 30);
    await expectLater(s.apply(Tx.sign(s1, TxType.settlePass, 0, forged.settleBody())), throwsRule('reader signed'));
    final forOther = Receipt.sign(reader, pass, pk(s2), 3000);
    await expectLater(s.apply(Tx.sign(s1, TxType.settlePass, 0, forOther.settleBody())), throwsRule('reader signed'));
    await s.apply(Tx.sign(s1, TxType.settlePass, 0, r1.settleBody()));
    await expectLater(
      s.apply(Tx.sign(s1, TxType.settlePass, 1, Receipt.sign(reader, pass, pk(s1), 9000).settleBody())),
      throwsRule('settled already'),
    );
    await s.apply(Tx.sign(s2, TxType.settlePass, 0, Receipt.sign(reader, pass, pk(s2), 1000).settleBody()));

    final burnedBefore = s.burned;
    closePasses(s, s.tick + p.passSettleTicks - 1);
    expect(s.passes, contains(pass), reason: 'the settlement window is still open');
    closePasses(s, s.tick + p.passSettleTicks);
    expect(s.passes, isEmpty);
    expect(s.balanceOf(pk(s1)), 3.75 * m, reason: 'three quarters of the servers\' half');
    expect(s.balanceOf(pk(s2)), 1.25 * m);
    expect(s.burned - burnedBefore, 5 * m);
    expect(s.burnsFor['tapes'], {0: 5 * m}, reason: 'an outsider\'s burn raises the collection\'s interest');
  });

  test('a pass nobody served returns the servers\' half; the burn stays', () async {
    final s = await circleSellingPasses();
    await s.apply(Tx.sign(reader, TxType.buyPass, 0, {'circle': 'radio'}));
    closePasses(s, s.tick + p.passTicks + p.passSettleTicks);
    expect(s.balanceOf(pk(reader)), 95 * m);
    expect(s.burnsFor, isEmpty, reason: 'the pass named no collection');
  });

  test('no passes from a circle that sells none or is cut off from the chain', () async {
    final free = await circleSellingPasses(price: 0);
    await expectLater(free.apply(Tx.sign(reader, TxType.buyPass, 0, {'circle': 'radio'})), throwsRule('does not sell'));
    final s = await circleSellingPasses();
    s.tick += p.anchorLifeTicks + 1;
    await expectLater(s.apply(Tx.sign(reader, TxType.buyPass, 0, {'circle': 'radio'})), throwsRule('cut off'));
    await expectLater(
      s.apply(Tx.sign(reader, TxType.buyPass, 0, {'circle': 'radio', 'collection': 'nope'})),
      throwsRule('cut off'),
    );
  });

  test('buying passes on your own files always loses half, and does not raise their interest', () async {
    final s = await circleSellingPasses();
    // The admin reads its own circle and serves itself.
    final buy = Tx.sign(admin, TxType.buyPass, 1, {'circle': 'radio', 'collection': 'tapes'});
    await s.apply(buy);
    s.tick += p.passTicks;
    await s.apply(Tx.sign(admin, TxType.settlePass, 2, Receipt.sign(admin, buy.id, pk(admin), 1 << 30).settleBody()));
    closePasses(s, s.tick + p.passSettleTicks);
    expect(s.balanceOf(pk(admin)), 95 * m);
    expect(s.burnsFor, isEmpty, reason: 'a member\'s burn is no sign of outside interest');
  });

  test('sync scores: rare data counts more, whole collections add, scores decay and reset on a missed proof', () {
    final s = library(
      circles: ['radio'],
      partitionSizes: [100, 100],
      collections: {
        'tapes': CollectionState(circle: 'radio', partitions: [1]),
      },
    );
    // Partition 0 has five keepers; partition 1 (the whole of "tapes") one.
    for (var i = 0; i < 5; i++) {
      keep(s, 'common$i', 'radio', [0]);
    }
    keep(s, 'rare', 'radio', [1]);
    proveAndClose(s);
    final scores = s.syncScores['radio']!;
    expect(scores['common0'], 100 * 10 ~/ 5);
    expect(scores['rare'], 100 * 10 + 100 * 10 ~/ 2, reason: 'rare partition, plus the whole collection');
    final before = scores['rare']!;
    // One day not kept, one kept again.
    s.declarations.remove('rare');
    proveAndClose(s);
    expect(s.syncScores['radio']!['rare'], before - before ~/ 7);
    keep(s, 'rare', 'radio', [1]);
    proveAndClose(s);
    expect(s.syncScores['radio']!['rare'], greaterThan(before));
    s.provenOn.remove('rare');
    s.startDay(s.day + 1);
    expect(s.syncScores['radio']?['rare'], isNull, reason: 'a missed proof resets the score');
  });
}
