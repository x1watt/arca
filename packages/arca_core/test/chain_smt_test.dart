import 'dart:math';

import 'package:arca_core/arca_core.dart';
import 'package:arca_core/src/chain/smt.dart';
import 'package:test/test.dart';

void main() {
  Map<String, String> randomEntries(Random rng, int n) => {
    for (var i = 0; i < n; i++) 'k${rng.nextInt(1 << 30)}': 'v$i',
  };

  test('the root depends on the entries, not the order they came in', () {
    final rng = Random(1);
    final e = randomEntries(rng, 200);
    final shuffled = Map.fromEntries(e.entries.toList()..shuffle(rng));
    expect(toHex(smtRoot(shuffled)), toHex(smtRoot(e)));
    expect(toHex(smtRoot({})), toHex(smtEmpty));
    expect(toHex(smtRoot({'a': '1'})), isNot(toHex(smtRoot({'a': '2'}))));
  });

  test('proves presence and absence; a proof for another root or a wrong value fails', () {
    final rng = Random(2);
    final e = randomEntries(rng, 300);
    final tree = SmtTree(e);
    final root = tree.root;
    for (final k in e.keys.take(20)) {
      final partial = SmtPartial.fromProofs(root, [tree.prove(k)]);
      expect(toHex(partial.valueHash(k)!), toHex(smtValueHash(e[k]!)));
    }
    for (final k in ['nope', 'absent', 'x1']) {
      expect(SmtPartial.fromProofs(root, [tree.prove(k)]).valueHash(k), isNull);
    }
    final other = SmtTree({...e, 'extra': '1'}).root;
    expect(() => SmtPartial.fromProofs(other, [tree.prove(e.keys.first)]), throwsA(isA<SmtError>()));
    // Claiming a different value for a present key.
    final p = tree.prove(e.keys.first);
    final lie = SmtProof(p.key, p.siblings, endPath: p.endPath, endValue: smtValueHash('lie'));
    expect(() => SmtPartial.fromProofs(root, [lie]), throwsA(isA<SmtError>()));
    // Hiding a present key behind "empty".
    final hide = SmtProof(p.key, p.siblings);
    expect(() => SmtPartial.fromProofs(root, [hide]), throwsA(isA<SmtError>()));
  });

  test('a verifier with some proofs applies inserts, updates and deletes and reaches the full tree\'s root', () {
    final rng = Random(3);
    for (var round = 0; round < 30; round++) {
      final e = randomEntries(rng, 1 + rng.nextInt(60));
      final tree = SmtTree(e);
      final keys = e.keys.toList();
      // Change a few keys: delete some, update some, insert new ones.
      final changes = <String, String?>{};
      for (var i = 0; i < 1 + rng.nextInt(5); i++) {
        switch (rng.nextInt(3)) {
          case 0:
            changes[keys[rng.nextInt(keys.length)]] = null;
          case 1:
            changes[keys[rng.nextInt(keys.length)]] = 'new${rng.nextInt(99)}';
          default:
            changes['fresh${rng.nextInt(1 << 20)}'] = 'x';
        }
      }
      final partial = SmtPartial.fromProofs(tree.root, [for (final k in changes.keys) tree.prove(k)]);
      final after = Map.of(e);
      changes.forEach((k, v) {
        partial.put(k, v);
        if (v == null) {
          after.remove(k);
        } else {
          after[k] = v;
        }
      });
      expect(toHex(partial.root), toHex(smtRoot(after)), reason: 'round $round, changes $changes');
    }
  });

  test('reading or changing a key that was not proven fails', () {
    final e = randomEntries(Random(4), 50);
    final tree = SmtTree(e);
    final partial = SmtPartial.fromProofs(tree.root, [tree.prove(e.keys.first)]);
    final unproven = e.keys.firstWhere((k) {
      try {
        partial.valueHash(k);
        return false;
      } on SmtError {
        return true;
      }
    });
    expect(() => partial.put(unproven, 'x'), throwsA(isA<SmtError>()));
  });
}
