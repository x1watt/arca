// Circles (whitepaper, section 4): the circle log and its seven rules,
// anchors carrying the log's roots and governance to the global chain,
// pool payout tables and claims.
import 'package:arca_core/arca_core.dart';
import 'package:arca_core/src/chain/circle_log.dart';
import 'package:arca_core/src/chain/params.dart';
import 'package:arca_core/src/chain/state.dart';
import 'package:arca_core/src/chain/tx.dart';
import 'package:test/test.dart';

const p = ChainParams.testnet;
const m = ChainParams.grainsPerMarca;
String pk(List<int> k) => toHex(publicKeyOf(k));

Matcher throwsRule(String text) => throwsA(predicate((e) => '$e'.contains(text), 'error containing "$text"'));

void main() {
  final admin = generateSecretKey();
  final mods = [for (var i = 0; i < 3; i++) generateSecretKey()];
  final alice = generateSecretKey(), bob = generateSecretKey(), eve = generateSecretKey();

  CircleLog withModerators() {
    final log = CircleLog('radio', admin: pk(admin));
    for (final mod in mods) {
      log.write(admin, LogType.appoint, {'key': pk(mod)});
    }
    return log;
  }

  group('the circle log', () {
    test('the admin appoints moderators and sets the policy, and cannot remove moderators', () {
      final log = withModerators();
      expect(log.moderators, hasLength(3));
      expect(() => log.write(mods[0], LogType.appoint, {'key': pk(eve)}), throwsRule('only the admin'));
      expect(() => log.write(admin, LogType.removeModerator, {'key': pk(mods[0])}), throwsRule('majority'));
      log.write(admin, LogType.policy, const CirclePolicy(openJoin: false, approvals: 2).toJson());
      expect(log.policy.approvals, 2);
      expect(
        () => log.write(admin, LogType.policy, {
          'payoutShares': {'keepers': 90},
        }),
        throwsRule('add up to 100'),
      );
    });

    test('moderators admit with as many approvals as the policy asks; joining follows the dial', () {
      final log = withModerators();
      log.write(alice, LogType.join, {'key': pk(alice)});
      expect(log.members, {pk(alice)});
      expect(() => log.write(bob, LogType.join, {'key': pk(alice)}), throwsRule('own key'));
      log.write(admin, LogType.policy, const CirclePolicy(openJoin: false, approvals: 2).toJson());
      expect(() => log.write(bob, LogType.join, {'key': pk(bob)}), throwsRule('by request'));
      expect(() => log.write(mods[0], LogType.admit, {'key': pk(bob)}), throwsRule('needs 2 moderator approvals'));
      expect(
        () => log.write(mods[0], LogType.admit, {'key': pk(bob)}, [eve]),
        throwsRule('needs 2'),
        reason: 'an outsider\'s signature is no approval',
      );
      log.write(mods[0], LogType.admit, {'key': pk(bob)}, [mods[1]]);
      expect(log.members, {pk(alice), pk(bob)});
      log.write(mods[1], LogType.exclude, {'key': pk(alice)}, [mods[2]]);
      expect(log.members, {pk(bob)});
      expect(() => log.write(admin, LogType.admit, {'key': pk(eve)}), throwsRule('only moderators'));
    });

    test(
      'a majority of moderators removes a moderator or replaces the admin; no admin and no moderators freezes it',
      () {
        final log = withModerators();
        expect(
          () => log.write(mods[0], LogType.replaceAdmin, {'key': pk(eve)}),
          throwsRule('majority of the 3 moderators, has 1'),
        );
        log.write(mods[0], LogType.replaceAdmin, {'key': pk(bob)}, [mods[1]]);
        expect(log.admin, pk(bob));
        expect(() => log.write(admin, LogType.appoint, {'key': pk(eve)}), throwsRule('only the admin'));
        log.write(mods[0], LogType.removeModerator, {'key': pk(mods[2])}, [mods[1]]);
        expect(log.moderators, hasLength(2));
        // Down to nothing: the two remove each other and the admin.
        log.write(mods[0], LogType.replaceAdmin, {'key': ''}, [mods[1]]);
        log.write(mods[0], LogType.removeModerator, {'key': pk(mods[1])}, [mods[1]]);
        log.write(mods[0], LogType.removeModerator, {'key': pk(mods[0])});
        expect(log.frozen, isTrue);
        expect(() => log.write(alice, LogType.join, {'key': pk(alice)}), throwsRule('frozen'));
      },
    );

    test('a replayed log reaches the same head and roots; an altered entry is refused', () {
      final log = withModerators()
        ..write(alice, LogType.join, {'key': pk(alice)})
        ..write(mods[0], LogType.collection, {
          'id': 'tapes',
          'partitions': [3, 1],
          'root': 'r' * 64,
        })
        ..write(mods[0], LogType.collection, {
          'id': 'private-tapes',
          'partitions': [2],
          'public': false,
        });
      final wire = [for (final e in log.entries) e.toJson()];
      final again = CircleLog.replay('radio', pk(admin), [for (final j in wire) LogEntry.fromJson(j)]);
      expect(again.head, log.head);
      expect(toHex(again.memberRoot()), toHex(log.memberRoot()));
      expect(again.anchorBody(), log.anchorBody());
      expect((log.anchorBody()['collections'] as Map).keys, ['tapes'], reason: 'closed collections never anchor');
      final altered = {
        ...wire[3],
        'body': {'key': pk(eve)},
      };
      expect(
        () => CircleLog.replay('radio', pk(admin), [
          for (final j in [...wire.take(3), altered]) LogEntry.fromJson(j),
        ]),
        throwsRule('bad signature'),
      );
    });
  });

  group('anchors on the chain', () {
    ChainState chain() => ChainState.genesis(
      p,
      circles: {
        'radio': CircleState(admin: pk(admin), name: 'Radio', moderators: [for (final x in mods) pk(x)]),
        'other': CircleState(admin: pk(eve), name: 'Other'),
      },
      collections: {
        'seeded': CollectionState(circle: 'radio', partitions: [0], seed: 50 * m),
      },
      partitionSizes: [256, 256, 256],
    );
    Map<String, String> sign(List<List<int>> who, String admin, List<String> moderators) => {
      for (final k in who) pk(k): toHex(schnorrSign(k, governanceMessage('radio', admin, moderators))),
    };

    test('the admin appoints; removing a moderator or replacing the admin takes a majority', () async {
      final s = chain();
      final all = [for (final x in mods) pk(x)];
      await s.apply(
        Tx.sign(admin, TxType.anchor, 0, {
          'circle': 'radio',
          'moderators': [...all, pk(bob)],
        }),
      );
      expect(s.circles['radio']!.moderators, hasLength(4));
      await expectLater(
        s.apply(
          Tx.sign(mods[0], TxType.anchor, 0, {
            'circle': 'radio',
            'moderators': [...all, pk(bob), pk(eve)],
          }),
        ),
        throwsRule('only the admin appoints'),
      );
      await expectLater(
        s.apply(Tx.sign(admin, TxType.anchor, 1, {'circle': 'radio', 'moderators': all})),
        throwsRule('majority of the 4 moderators, has 0'),
        reason: 'the admin cannot remove moderators',
      );
      final four = [...all, pk(bob)];
      await expectLater(
        s.apply(
          Tx.sign(mods[0], TxType.anchor, 0, {
            'circle': 'radio',
            'admin': pk(alice),
            'approvals': sign([mods[0], mods[1]], pk(alice), four),
          }),
        ),
        throwsRule('has 2'),
        reason: 'two of four is no majority',
      );
      await s.apply(
        Tx.sign(mods[0], TxType.anchor, 0, {
          'circle': 'radio',
          'admin': pk(alice),
          'approvals': sign([mods[0], mods[1], mods[2]], pk(alice), four),
        }),
      );
      expect(s.circles['radio']!.admin, pk(alice));
    });

    test('an anchor lists the circle\'s public collections, keeps seeds, and cannot take another circle\'s', () async {
      final s = chain();
      await s.apply(
        Tx.sign(mods[0], TxType.anchor, 0, {
          'circle': 'radio',
          'collections': {
            'seeded': [0],
            'tapes': [1, 2],
          },
        }),
      );
      expect(s.collections['seeded']!.seed, 50 * m);
      expect(s.collections['tapes']!.partitions, [1, 2]);
      await s.apply(
        Tx.sign(mods[0], TxType.anchor, 1, {
          'circle': 'radio',
          'collections': {
            'seeded': [0],
          },
        }),
      );
      expect(s.collections.keys, ['seeded'], reason: 'unlisted collections leave');
      await expectLater(
        s.apply(
          Tx.sign(eve, TxType.anchor, 0, {
            'circle': 'other',
            'collections': {
              'seeded': [0],
            },
          }),
        ),
        throwsRule('another circle'),
      );
      await expectLater(
        s.apply(
          Tx.sign(eve, TxType.anchor, 0, {
            'circle': 'other',
            'collections': {
              'far': [9],
            },
          }),
        ),
        throwsRule('no such partition'),
      );
    });
  });

  test('pool payouts: the admin publishes cumulative totals, members claim the difference once', () async {
    final log = withModerators()
      ..write(alice, LogType.join, {'key': pk(alice)})
      ..write(bob, LogType.join, {'key': pk(bob)});
    final s = ChainState.genesis(
      p,
      circles: {
        'radio': CircleState(admin: pk(admin), name: 'Radio', moderators: [for (final x in mods) pk(x)]),
      },
    );
    s.circles['radio']!.pool = 1000 * m;
    // The admin's software splits the pool's 1,000 marcas by the policy:
    // 45% keepers, 45% contributors, 10% moderators.
    final totals = distribute(1000 * m, log.policy.payoutShares, {
      'keepers': {pk(alice): 3, pk(bob): 1},
      'contributors': {pk(bob): 1},
      'moderators': {pk(mods[0]): 1},
    }, const {});
    expect(totals[pk(alice)], 337.5 * m);
    expect(totals[pk(bob)], 112.5 * m + 450 * m);
    expect(totals.values.fold(0, (a, b) => a + b), lessThanOrEqualTo(1000 * m));
    log.write(admin, LogType.payout, {'table': totals});
    await s.apply(Tx.sign(mods[0], TxType.anchor, 0, log.anchorBody()));

    final table = log.payoutTable();
    await s.apply(Tx.sign(alice, TxType.claim, 0, table.claimBody(pk(alice))));
    expect(s.balanceOf(pk(alice)), 337.5 * m);
    expect(s.circles['radio']!.pool, 1000 * m - 337.5 * m);
    await expectLater(s.apply(Tx.sign(alice, TxType.claim, 1, table.claimBody(pk(alice)))), throwsRule('nothing left'));
    // Claiming someone else's line, or a bigger total, fails the proof.
    await expectLater(s.apply(Tx.sign(eve, TxType.claim, 0, table.claimBody(pk(alice)))), throwsRule('payout table'));
    final inflated = {...table.claimBody(pk(bob)), 'total': 10000 * m};
    await expectLater(s.apply(Tx.sign(bob, TxType.claim, 0, inflated)), throwsRule('payout table'));

    // The pool earns more; the table grows; alice claims only the new part.
    s.circles['radio']!.pool += 400 * m;
    final more = distribute(400 * m, log.policy.payoutShares, {
      'keepers': {pk(alice): 1},
    }, log.payouts);
    log.write(admin, LogType.payout, {'table': more});
    expect(() => log.write(admin, LogType.payout, {'table': totals}), throwsRule('only grow'));
    await s.apply(Tx.sign(mods[0], TxType.anchor, 1, log.anchorBody()));
    await s.apply(Tx.sign(alice, TxType.claim, 1, log.payoutTable().claimBody(pk(alice))));
    expect(s.balanceOf(pk(alice)), 337.5 * m + 180 * m);
    await s.apply(Tx.sign(bob, TxType.claim, 0, log.payoutTable().claimBody(pk(bob))));
    expect(s.balanceOf(pk(bob)), 562.5 * m);
  });
}
