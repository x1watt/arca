// Bulletproof range proofs (Bünz, Bootle, Boneh, Poelstra, Wuille, Maxwell,
// 2018): a commitment V = γ·G + v·H holds a value 0 <= v < 2^64, shown in
// 688 bytes without revealing v. Without them a transaction could spend
// 10 marcas into outputs of 1 000 010 and -1 000 000, balancing the
// commitments while creating money (docs/architecture.md, 10).
//
// The prover commits to the bits of v, and an inner product argument
// shows in log2(64) = 6 rounds that the committed vectors satisfy the
// bit constraints. The verifier folds every check into one weighted
// multi-exponentiation that must come to the point at infinity.
// Challenges are Fiat-Shamir hashes chained from V.

import 'dart:math';
import 'dart:typed_data';

import 'curve.dart';
import 'pedersen.dart';

const _bits = 64;
const _rounds = 6; // log2(_bits)

final List<Point> _gs = [for (var i = 0; i < _bits; i++) Point.hashToCurve('arca/bp/G/$i')];
final List<Point> _hs = [for (var i = 0; i < _bits; i++) Point.hashToCurve('arca/bp/H/$i')];
final Point _u = Point.hashToCurve('arca/bp/U');

final _nMod = curveN;
BigInt _s(BigInt a) => a % _nMod;

BigInt _inner(List<BigInt> a, List<BigInt> b) {
  var r = BigInt.zero;
  for (var i = 0; i < a.length; i++) {
    r += a[i] * b[i];
  }
  return _s(r);
}

List<BigInt> _powers(BigInt x, int n) {
  final out = <BigInt>[];
  var p = BigInt.one;
  for (var i = 0; i < n; i++) {
    out.add(p);
    p = _s(p * x);
  }
  return out;
}

class RangeProof {
  RangeProof._(this.a, this.s, this.t1, this.t2, this.taux, this.mu, this.that, this.ls, this.rs, this.aFinal, this.bFinal);

  final Point a, s, t1, t2;
  final BigInt taux, mu, that;
  final List<Point> ls, rs;
  final BigInt aFinal, bFinal;

  static const byteLength = 4 * 33 + 3 * 32 + 2 * _rounds * 33 + 2 * 32;

  Uint8List get bytes => Uint8List.fromList([
    ...a.encoded,
    ...s.encoded,
    ...t1.encoded,
    ...t2.encoded,
    ...scalarBytes(taux),
    ...scalarBytes(mu),
    ...scalarBytes(that),
    for (final l in ls) ...l.encoded,
    for (final r in rs) ...r.encoded,
    ...scalarBytes(aFinal),
    ...scalarBytes(bFinal),
  ]);

  /// The proof [b] encodes, or null.
  static RangeProof? fromBytes(List<int> b) {
    if (b.length != byteLength) return null;
    var at = 0;
    Point? point() {
      final p = Point.decode(b.sublist(at, at + 33));
      at += 33;
      return p;
    }

    BigInt? scalar() {
      final v = scalarOf(b.sublist(at, at + 32));
      at += 32;
      return v < curveN ? v : null;
    }

    final a = point(), s = point(), t1 = point(), t2 = point();
    final taux = scalar(), mu = scalar(), that = scalar();
    final ls = [for (var i = 0; i < _rounds; i++) point()];
    final rs = [for (var i = 0; i < _rounds; i++) point()];
    final af = scalar(), bf = scalar();
    if ([a, s, t1, t2, taux, mu, that, af, bf, ...ls, ...rs].contains(null)) return null;
    return RangeProof._(a!, s!, t1!, t2!, taux!, mu!, that!, ls.cast<Point>(), rs.cast<Point>(), af!, bf!);
  }

  /// A proof that [commitment] = [blinding]·G + [value]·H holds a value
  /// in [0, 2^64).
  static RangeProof prove(BigInt value, BigInt blinding, {Point? commitment, Random? random}) {
    if (value < BigInt.zero || value.bitLength > _bits) throw ArgumentError('value out of range');
    final v = commitment ?? commit(value, blinding);
    BigInt rnd() => randomScalar(random);
    final aL = [for (var i = 0; i < _bits; i++) (value >> i) & BigInt.one];
    final aR = [for (final b in aL) _s(b - BigInt.one)];
    final alpha = rnd(), rho = rnd();
    final sL = [for (var i = 0; i < _bits; i++) rnd()];
    final sR = [for (var i = 0; i < _bits; i++) rnd()];
    final a = Point.multiExp([blindingBase, ..._gs, ..._hs], [alpha, ...aL, ...aR]);
    final s = Point.multiExp([blindingBase, ..._gs, ..._hs], [rho, ...sL, ...sR]);
    final y = hashToScalar('arca/bp/y', [v, a, s]);
    final z = hashToScalar('arca/bp/z', [v, a, s, y]);
    final yn = _powers(y, _bits), twos = _powers(BigInt.two, _bits);
    final z2 = _s(z * z);
    final l0 = [for (final b in aL) _s(b - z)];
    final l1 = sL;
    final r0 = [for (var i = 0; i < _bits; i++) _s(yn[i] * (aR[i] + z) + z2 * twos[i])];
    final r1 = [for (var i = 0; i < _bits; i++) _s(yn[i] * sR[i])];
    final t1 = _s(_inner(l0, r1) + _inner(l1, r0));
    final t2 = _inner(l1, r1);
    final tau1 = rnd(), tau2 = rnd();
    final bigT1 = Point.multiExp([valueBase, blindingBase], [t1, tau1]);
    final bigT2 = Point.multiExp([valueBase, blindingBase], [t2, tau2]);
    final x = hashToScalar('arca/bp/x', [z, bigT1, bigT2]);
    final l = [for (var i = 0; i < _bits; i++) _s(l0[i] + l1[i] * x)];
    final r = [for (var i = 0; i < _bits; i++) _s(r0[i] + r1[i] * x)];
    final that = _inner(l, r);
    final taux = _s(tau2 * x * x + tau1 * x + z2 * blinding);
    final mu = _s(alpha + rho * x);
    final w = hashToScalar('arca/bp/w', [x, taux, mu, that]);
    final q = _u * w;
    // The inner product argument over G and H' (H'_i = y^-i·H_i).
    final yInv = scalarInverse(y);
    final yInvN = _powers(yInv, _bits);
    var gs = [..._gs];
    var hs = [for (var i = 0; i < _bits; i++) _hs[i] * yInvN[i]];
    var av = l, bv = r;
    final ls = <Point>[], rs = <Point>[];
    var prev = w;
    while (av.length > 1) {
      final m = av.length ~/ 2;
      final aLo = av.sublist(0, m), aHi = av.sublist(m);
      final bLo = bv.sublist(0, m), bHi = bv.sublist(m);
      final gLo = gs.sublist(0, m), gHi = gs.sublist(m);
      final hLo = hs.sublist(0, m), hHi = hs.sublist(m);
      final cL = _inner(aLo, bHi), cR = _inner(aHi, bLo);
      final bigL = Point.multiExp([...gHi, ...hLo, q], [...aLo, ...bHi, cL]);
      final bigR = Point.multiExp([...gLo, ...hHi, q], [...aHi, ...bLo, cR]);
      ls.add(bigL);
      rs.add(bigR);
      final u = hashToScalar('arca/bp/u', [prev, bigL, bigR]);
      prev = u;
      final ui = scalarInverse(u);
      av = [for (var i = 0; i < m; i++) _s(aLo[i] * u + aHi[i] * ui)];
      bv = [for (var i = 0; i < m; i++) _s(bLo[i] * ui + bHi[i] * u)];
      gs = [for (var i = 0; i < m; i++) Point.multiExp([gLo[i], gHi[i]], [ui, u])];
      hs = [for (var i = 0; i < m; i++) Point.multiExp([hLo[i], hHi[i]], [u, ui])];
    }
    return RangeProof._(a, s, bigT1, bigT2, taux, mu, that, ls, rs, av.single, bv.single);
  }

  /// Whether this proves [commitment] holds a value in [0, 2^64).
  bool verify(Point commitment, {Random? random}) {
    final v = commitment;
    final y = hashToScalar('arca/bp/y', [v, a, s]);
    final z = hashToScalar('arca/bp/z', [v, a, s, y]);
    final x = hashToScalar('arca/bp/x', [z, t1, t2]);
    final w = hashToScalar('arca/bp/w', [x, taux, mu, that]);
    if (y == BigInt.zero || z == BigInt.zero || x == BigInt.zero) return false;
    final us = <BigInt>[];
    var prev = w;
    for (var j = 0; j < _rounds; j++) {
      final u = hashToScalar('arca/bp/u', [prev, ls[j], rs[j]]);
      if (u == BigInt.zero) return false;
      us.add(u);
      prev = u;
    }
    final usInv = [for (final u in us) scalarInverse(u)];
    final yn = _powers(y, _bits), twos = _powers(BigInt.two, _bits);
    final yInvN = _powers(scalarInverse(y), _bits);
    final z2 = _s(z * z), z3 = _s(z2 * z);
    var sumY = BigInt.zero, sumTwo = BigInt.zero;
    for (var i = 0; i < _bits; i++) {
      sumY += yn[i];
      sumTwo += twos[i];
    }
    final delta = _s((z - z2) * sumY - z3 * sumTwo);
    // s_i: the product of u_j (index in the upper half at round j) or
    // u_j^-1 (lower half), the first round deciding the top bit.
    final sv = <BigInt>[];
    for (var i = 0; i < _bits; i++) {
      var si = BigInt.one;
      for (var j = 0; j < _rounds; j++) {
        final upper = (i >> (_rounds - 1 - j)) & 1 == 1;
        si = _s(si * (upper ? us[j] : usInv[j]));
      }
      sv.add(si);
    }
    // A random weight joins the polynomial check to the argument's.
    final c = randomScalar(random);
    final points = <Point>[], ks = <BigInt>[];
    void add(Point p, BigInt k) {
      points.add(p);
      ks.add(_s(k));
    }

    for (var i = 0; i < _bits; i++) {
      add(_gs[i], -z - aFinal * sv[i]);
      final hCoef = (z * yn[i] + z2 * twos[i]) * yInvN[i] - bFinal * scalarInverse(sv[i]) * yInvN[i];
      add(_hs[i], hCoef);
    }
    add(a, BigInt.one);
    add(s, x);
    for (var j = 0; j < _rounds; j++) {
      add(ls[j], us[j] * us[j]);
      add(rs[j], usInv[j] * usInv[j]);
    }
    add(_u, w * (that - aFinal * bFinal));
    add(blindingBase, -mu + c * taux);
    add(valueBase, c * (that - delta));
    add(v, -c * z2);
    add(t1, -c * x);
    add(t2, -c * x * x);
    return Point.multiExp(points, ks).isInfinity;
  }
}
