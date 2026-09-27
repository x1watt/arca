// Private marcas on the chain (private_tx.dart): moving marcas from a public
// balance to the private side, paying another wallet without naming either,
// finding what arrived with the scan key, and the ways a transaction could
// cheat: making marcas, spending twice, spending another's output, changing
// a signed transaction. The private side must always add up (auditSupply).
import 'dart:convert';
import 'dart:math';

import 'package:arca_core/src/chain/params.dart';
import 'package:arca_core/src/chain/private_tx.dart';
import 'package:arca_core/src/chain/state.dart';
import 'package:arca_core/src/chain/tx.dart';
import 'package:arca_core/src/chain/wallet_keys.dart';
import 'package:arca_core/src/crypto/bulletproof.dart';
import 'package:arca_core/src/crypto/curve.dart';
import 'package:arca_core/src/crypto/hex.dart';
import 'package:arca_core/src/crypto/pedersen.dart';
import 'package:arca_core/src/crypto/point_schnorr.dart';
import 'package:arca_core/src/crypto/schnorr.dart';
import 'package:test/test.dart';

const p = ChainParams.testnet;
final m = BigInt.from(ChainParams.grainsPerMarca);

void main() {
  final rng = Random(4);
  final alice = generateSecretKey(), bob = generateSecretKey();
  final aliceKeys = WalletKeys.of(alice), bobKeys = WalletKeys.of(bob);
  final alicePub = toHex(publicKeyOf(alice)), bobPub = toHex(publicKeyOf(bob));

  ChainState genesis() => ChainState.genesis(p, allocations: {alicePub: 100 * ChainParams.grainsPerMarca});

  /// What [keys] owns among the unspent outputs of [s].
  List<Owned> scan(ChainState s, WalletKeys keys) => [
    for (final e in s.outputs.raw.entries)
      if (OutputEntry.fromJson(jsonDecode(e.value) as Map) case final o?)
        if (keys.view.recognise(o.r, o.k, o.tag) case final t?)
          if (openOutput(Point.decode(fromHex(e.key))!, o.encryptedValue, t) case final v?)
            Owned(commitment: e.key, value: v, blinding: stealthBlinding(t), t: t),
  ];

  BigInt total(List<Owned> os) => os.fold(BigInt.zero, (a, o) => a + o.value);

  Tx anonymous(Map<String, Object?> body) => Tx(type: TxType.private, from: '', nonce: 0, body: body, sig: '');

  Future<ChainState> applied(ChainState s, Tx tx) async {
    final next = s.copy();
    await next.apply(tx);
    expect(auditSupply(next), isNull, reason: 'the private side adds up');
    return next;
  }

  /// Alice moves 60 marcas to her private side.
  Future<ChainState> shielded() async {
    final built = await buildPrivate(
      signInput: localSigner(aliceKeys),
      inputs: const [],
      payments: [(aliceKeys.address, BigInt.from(60) * m)],
      pub: 60 * ChainParams.grainsPerMarca,
      from: alicePub,
      random: rng,
    );
    return applied(genesis(), Tx.sign(alice, TxType.private, 0, built.body));
  }

  test('moving marcas in, paying another wallet, finding them, moving them out', () async {
    var s = await shielded();
    expect(s.balanceOf(alicePub), 40 * ChainParams.grainsPerMarca);
    expect(s.privateSupply, 60 * ChainParams.grainsPerMarca);
    final mine = scan(s, aliceKeys);
    expect(total(mine), BigInt.from(60) * m);
    expect(scan(s, bobKeys), isEmpty);

    // Alice pays Bob 25 with change back to herself; no account appears.
    final pay = await buildPrivate(
      signInput: localSigner(aliceKeys),
      inputs: mine,
      payments: [(bobKeys.address, BigInt.from(25) * m), (aliceKeys.address, BigInt.from(35) * m)],
      random: rng,
    );
    final tx = anonymous(pay.body);
    s = await applied(s, tx);
    expect(tx.from, isEmpty);
    expect(jsonEncode(tx.toJson()).contains(bobPub), isFalse);
    expect(total(scan(s, bobKeys)), BigInt.from(25) * m, reason: 'Bob finds what he was sent');
    expect(total(scan(s, aliceKeys)), BigInt.from(35) * m, reason: 'and Alice her change');
    expect(s.privateSupply, 60 * ChainParams.grainsPerMarca, reason: 'a payment moves nothing in or out');

    // A payment proof: e shows the output paid Bob 25.
    final sent = pay.made.first;
    expect(checkPaymentProof(sent.e, bobKeys.address, sent.r, sent.k, sent.commitment, sent.encryptedValue), BigInt.from(25) * m);

    // An auditor with Bob's view key sees his outputs.
    final auditor = WalletKeys.parseViewKey(bobKeys.viewKey)!;
    final seen = [
      for (final e in s.outputs.raw.entries)
        if (OutputEntry.fromJson(jsonDecode(e.value) as Map) case final o?)
          if (auditor.recognise(o.r, o.k, o.tag) != null) e.key,
    ];
    expect(seen, hasLength(1));

    // Bob moves 5 out to his public balance.
    final out = await buildPrivate(
      signInput: localSigner(bobKeys),
      inputs: scan(s, bobKeys),
      payments: [(bobKeys.address, BigInt.from(20) * m)],
      pub: -5 * ChainParams.grainsPerMarca,
      from: bobPub,
      random: rng,
    );
    s = await applied(s, Tx.sign(bob, TxType.private, 0, out.body));
    expect(s.balanceOf(bobPub), 5 * ChainParams.grainsPerMarca);
    expect(s.privateSupply, 55 * ChainParams.grainsPerMarca);
    expect(total(scan(s, bobKeys)), BigInt.from(20) * m);
  });

  test('a transaction cannot make marcas, spend twice, spend another\'s output or be changed', () async {
    final s = await shielded();
    final mine = scan(s, aliceKeys);
    Future<String> refused(Tx tx) async {
      try {
        await s.copy().apply(tx);
      } on ChainError catch (e) {
        return e.message;
      }
      fail('accepted');
    }

    // More out than in.
    var built = await buildPrivate(signInput: localSigner(aliceKeys), inputs: mine, payments: [(bobKeys.address, BigInt.from(70) * m)], random: rng);
    expect(await refused(anonymous(built.body)), contains('does not balance'));

    // 70 to Bob and -10 to nobody balances 60 in; the -10 has no range
    // proof of its own, so it borrows Bob's. Everything else is signed.
    final toBob = StealthOutput.to(bobKeys.address, BigInt.from(70) * m, random: rng);
    final rNeg = randomScalar(rng);
    final negative = commit(curveN - BigInt.from(10) * m, rNeg);
    final proof = toHex(RangeProof.prove(toBob.value, toBob.blinding, commitment: toBob.commitment, random: rng).bytes);
    Map<String, Object?> out(Point c) => {
      'c': toHex(c.encoded),
      'r': toHex(toBob.r.encoded),
      'k': toHex(toBob.k.encoded),
      'tag': toBob.tag,
      'v': toHex(valueBytes(toBob.encryptedValue)),
      'proof': proof,
    };
    final secret = (toBob.blinding + rNeg - mine.fold(BigInt.zero, (a, o) => a + o.blinding)) % curveN;
    final forgedUnsigned = <String, Object?>{
      'inputs': [
        for (final i in mine) {'c': i.commitment},
      ],
      'outputs': [out(toBob.commitment), out(negative)],
      'kernel': {'excess': toHex((Point.g * secret).encoded), 'pub': 0},
    };
    final msg = privateMessage('', 0, forgedUnsigned);
    final forged = <String, Object?>{
      'inputs': [
        for (final i in mine) {'c': i.commitment, 'sig': toHex(pointSign(aliceKeys.oneTimeSecret(i.t), msg))},
      ],
      'outputs': forgedUnsigned['outputs'],
      'kernel': {...forgedUnsigned['kernel'] as Map, 'sig': toHex(pointSign(secret, msg))},
    };
    expect(await refused(anonymous(forged)), contains('range proof'));
    built = await buildPrivate(signInput: localSigner(aliceKeys), inputs: mine, payments: [(bobKeys.address, BigInt.from(60) * m)], random: rng);

    // Twice.
    final ok = anonymous(built.body);
    final after = await applied(s, ok);
    try {
      await after.copy().apply(ok);
      fail('spent twice');
    } on ChainError catch (e) {
      expect(e.message, contains('no such unspent output'));
    }

    // Alice sent Bob his output and knows its blinding and t; without b
    // she cannot sign it away.
    final bobs = scan(after, bobKeys).single;
    final theft = await buildPrivate(
      signInput: localSigner(aliceKeys),
      inputs: [Owned(commitment: bobs.commitment, value: bobs.value, blinding: bobs.blinding, t: bobs.t)],
      payments: [(aliceKeys.address, bobs.value)],
      random: rng,
    );
    try {
      await after.copy().apply(anonymous(theft.body));
      fail('stolen');
    } on ChainError catch (e) {
      expect(e.message, contains('not signed by its owner'));
    }

    // Changed after signing: the value to another amount's encryption.
    final changed = jsonDecode(jsonEncode(built.body)) as Map<String, Object?>;
    ((changed['outputs'] as List).first as Map)['v'] = '00' * 8;
    expect(await refused(anonymous(changed)), contains('signature'));

    // Moving public marcas without the balance's key, or a payment that
    // names an account.
    final unsigned = await buildPrivate(
      signInput: localSigner(aliceKeys),
      inputs: const [],
      payments: [(aliceKeys.address, BigInt.from(5) * m)],
      pub: 5 * ChainParams.grainsPerMarca,
      random: rng,
    );
    expect(await refused(anonymous(unsigned.body)), contains('balance\'s signature'));
    expect(
      await refused(Tx.sign(alice, TxType.private, 1, (await buildPrivate(signInput: localSigner(aliceKeys), inputs: mine, payments: [(bobKeys.address, BigInt.from(60) * m)], from: alicePub, nonce: 1, random: rng)).body)),
      contains('names no account'),
    );
  });

  test('the supply check catches an output that was slipped into the state', () async {
    final s = await shielded();
    expect(auditSupply(s), isNull);
    final fake = commit(BigInt.from(1000) * m, randomScalar(rng));
    final entry = OutputEntry(Point.g * randomScalar(rng), Point.g * randomScalar(rng), 0, BigInt.zero);
    s.outputs[toHex(fake.encoded)] = jsonEncode(entry.toJson());
    expect(auditSupply(s), contains('do not add up'));
    expect(RangeProof.byteLength, 688);
  });
}
