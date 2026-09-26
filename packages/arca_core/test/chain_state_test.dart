import 'package:arca_core/arca_core.dart';
import 'package:arca_core/src/chain/block.dart';
import 'package:arca_core/src/chain/params.dart';
import 'package:arca_core/src/chain/state.dart';
import 'package:arca_core/src/chain/tx.dart';
import 'package:test/test.dart';

void main() {
  const p = ChainParams.testnet;
  const m = ChainParams.grainsPerMarca;
  final alice = generateSecretKey(), bob = generateSecretKey(), producer = generateSecretKey();
  String pk(List<int> k) => toHex(publicKeyOf(k));
  ChainState genesis() => ChainState.genesis(p, allocations: {pk(alice): 10000 * m});

  test('transfers move marcas; nonces stop replays; overspends and forgeries fail', () async {
    final s = genesis();
    final t = Tx.sign(alice, TxType.transfer, 0, {'to': pk(bob), 'amount': 250 * m});
    await s.apply(t);
    expect(s.balanceOf(pk(bob)), 250 * m);
    expect(s.balanceOf(pk(alice)), 9750 * m);
    await expectLater(() => s.apply(t), throwsA(isA<ChainError>()), reason: 'replayed');
    await expectLater(
      () => s.apply(Tx.sign(bob, TxType.transfer, 0, {'to': pk(alice), 'amount': 251 * m})),
      throwsA(predicate((e) => '$e'.contains('balance'))),
    );
    final forged = Tx(type: t.type, from: pk(alice), nonce: 1, body: {'to': pk(bob), 'amount': 1}, sig: t.sig);
    await expectLater(() => s.apply(forged), throwsA(predicate((e) => '$e'.contains('signature'))));
  });

  test('creating a circle burns the fee; only its admin sets moderators; admin and moderators anchor', () async {
    final s = genesis();
    await s.apply(Tx.sign(alice, TxType.createCircle, 0, {'circle': 'radio-archive', 'name': 'Radio archive'}));
    expect(s.burned, p.circleFee);
    expect(s.balanceOf(pk(alice)), 10000 * m - p.circleFee);
    await expectLater(
      () => s.apply(Tx.sign(alice, TxType.createCircle, 1, {'circle': 'radio-archive'})),
      throwsA(isA<ChainError>()),
    );
    await s.apply(
      Tx.sign(alice, TxType.anchor, 1, {
        'circle': 'radio-archive',
        'logHead': 'h1',
        'moderators': [pk(bob)],
      }),
    );
    await s.apply(Tx.sign(bob, TxType.anchor, 0, {'circle': 'radio-archive', 'logHead': 'h2'}));
    expect(s.circles['radio-archive']!.logHead, 'h2');
    await expectLater(
      () => s.apply(Tx.sign(bob, TxType.anchor, 1, {'circle': 'radio-archive', 'moderators': <String>[]})),
      throwsA(predicate((e) => '$e'.contains('only the admin'))),
    );
    await expectLater(
      () => s.apply(Tx.sign(producer, TxType.anchor, 0, {'circle': 'radio-archive'})),
      throwsA(isA<ChainError>()),
    );
  });

  test('stewards declare and drop partitions for a circle', () async {
    final s = genesis()..apply(Tx.sign(alice, TxType.createCircle, 0, {'circle': 'commons'}));
    await s.apply(
      Tx.sign(bob, TxType.declare, 0, {
        'circle': 'commons',
        'partitions': [0, 3],
      }),
    );
    expect(s.declarations[pk(bob)], {0: 'commons', 3: 'commons'});
    await s.apply(
      Tx.sign(bob, TxType.undeclare, 1, {
        'partitions': [0, 3],
      }),
    );
    expect(s.declarations.containsKey(pk(bob)), isFalse);
  });

  test('every node that applies the same blocks holds the same state root', () async {
    var a = genesis(), b = genesis();
    for (var h = 1; h <= 3; h++) {
      final block = await Block.produce(a, producer, [
        Tx.sign(alice, TxType.transfer, h - 1, {'to': pk(bob), 'amount': h * m}),
      ], tick: h * 10);
      a = await block.applyTo(a);
      b = await Block.fromJson(block.toJson()).applyTo(b);
      expect(b.rootHex, a.rootHex);
      expect(b.head, a.head);
    }
    expect(a.balanceOf(pk(bob)), 6 * m);
    expect(a.height, 3);
  });

  test('tampered blocks are rejected', () async {
    final s = genesis();
    final block = await Block.produce(s, producer, [
      Tx.sign(alice, TxType.transfer, 0, {'to': pk(bob), 'amount': m}),
    ], tick: 5);
    Block change(Map<String, Object?> Function(Map<String, Object?>) f) => Block.fromJson(f(block.toJson()));
    // A different state than the one the transactions produce.
    final evilState = await Block.produce(s, producer, const [], tick: 5);
    await expectLater(
      () => change((j) => {...j, 'stateRoot': evilState.stateRoot}).applyTo(s),
      throwsA(isA<ChainError>()),
    );
    // A transaction slipped in after signing.
    expect(
      () => change(
        (j) => {
          ...j,
          'txs': [
            ...(j['txs'] as List),
            Tx.sign(alice, TxType.transfer, 1, {'to': pk(bob), 'amount': m}).toJson(),
          ],
        },
      ).applyTo(s),
      throwsA(isA<ChainError>()),
    );
    // Not following the head, and a bad signature.
    await expectLater(() => change((j) => {...j, 'prev': 'ff'}).applyTo(s), throwsA(isA<ChainError>()));
    await expectLater(() => change((j) => {...j, 'producer': pk(bob)}).applyTo(s), throwsA(isA<ChainError>()));
    expect((await block.applyTo(s)).height, 1);
  });
}
