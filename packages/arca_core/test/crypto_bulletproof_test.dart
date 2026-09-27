// The primitives of private marcas: points, commitments, signatures by any
// point, and 64-bit range proofs (docs/architecture.md, 10).
import 'dart:math';

import 'package:arca_core/src/crypto/bulletproof.dart';
import 'package:arca_core/src/crypto/curve.dart';
import 'package:arca_core/src/crypto/pedersen.dart';
import 'package:arca_core/src/crypto/point_schnorr.dart';
import 'package:test/test.dart';

void main() {
  final rng = Random(9);
  BigInt k(int v) => BigInt.from(v);

  test('points: arithmetic, encoding, and the fixed bases agree with plain products', () {
    final a = randomScalar(rng), b = randomScalar(rng);
    expect(Point.g * a + Point.g * b, Point.g * ((a + b) % curveN));
    expect(Point.g * a - Point.g * a, Point.infinity);
    final p = Point.g * a;
    expect(Point.decode(p.encoded), p);
    expect(Point.decode((-p).encoded), -p);
    expect(Point.multiExp([Point.g, valueBase], [a, b]), Point.g * a + valueBase * b);
    expect(valueBase * a, Point.multiExp([valueBase], [a]), reason: 'table and plain agree');
    expect(Point.decode([5, ...List.filled(32, 1)]), isNull);
  });

  test('commitments add up and hide the value', () {
    final r1 = randomScalar(rng), r2 = randomScalar(rng);
    expect(commit(k(3), r1) + commit(k(4), r2), commit(k(7), (r1 + r2) % curveN));
    expect(commit(k(3), r1) == commit(k(3), r2), isFalse);
  });

  test('a signature by a point checks only for its key and message', () {
    final d = randomScalar(rng);
    final key = Point.g * d;
    final sig = pointSign(d, [1, 2, 3]);
    expect(pointVerify(key, [1, 2, 3], sig), isTrue);
    expect(pointVerify(key, [1, 2, 4], sig), isFalse);
    expect(pointVerify(Point.g * randomScalar(rng), [1, 2, 3], sig), isFalse);
    final bad = [...sig]..[40] ^= 1;
    expect(pointVerify(key, [1, 2, 3], bad), isFalse);
  });

  test('range proofs hold for values in [0, 2^64) and fail for anything else', () {
    for (final v in [BigInt.zero, BigInt.one, BigInt.from(123456789), (BigInt.one << 64) - BigInt.one]) {
      final r = randomScalar(rng);
      final sw = Stopwatch()..start();
      final proof = RangeProof.prove(v, r, random: rng);
      final proveMs = sw.elapsedMilliseconds;
      sw.reset();
      final c = commit(v, r);
      expect(proof.verify(c), isTrue, reason: 'value $v');
      print('value $v: prove $proveMs ms, verify ${sw.elapsedMilliseconds} ms, ${proof.bytes.length} bytes');
      final again = RangeProof.fromBytes(proof.bytes)!;
      expect(again.verify(c), isTrue, reason: 'survives encoding');
    }
    final r = randomScalar(rng);
    final proof = RangeProof.prove(k(42), r, random: rng);
    expect(proof.verify(commit(k(43), r)), isFalse, reason: 'another value');
    expect(proof.verify(commit(k(42), randomScalar(rng))), isFalse, reason: 'another blinding');
    final bytes = proof.bytes;
    for (final at in [5, 140, 300, 600, RangeProof.byteLength - 3]) {
      final t = [...bytes]..[at] ^= 1;
      final p = RangeProof.fromBytes(t);
      expect(p == null || !p.verify(commit(k(42), r)), isTrue, reason: 'byte $at changed');
    }
    expect(() => RangeProof.prove(BigInt.one << 64, r), throwsArgumentError);
    expect(() => RangeProof.prove(-BigInt.one, r), throwsArgumentError);
  });
}
