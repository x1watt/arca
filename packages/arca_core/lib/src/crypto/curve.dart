// secp256k1 points and scalars for the chain's private money (commitments,
// range proofs, stealth keys): docs/architecture.md, 10.
//
// Pure Dart on BigInt, like schnorr.dart, so it runs anywhere Dart does.
// Not constant time: secrets are only handled on the device that owns
// them, on the chain worker's isolate. Points are kept in Jacobian
// coordinates; the fixed bases (G, and the value base of commitments) get
// precomputed tables, and sums of many products use one interleaved pass
// (multiExp), which is what range proofs spend their time on.

import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as c;

final BigInt fieldP = BigInt.parse('FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F', radix: 16);

/// The group order: scalars live modulo it.
final BigInt curveN = BigInt.parse('FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141', radix: 16);
final BigInt _sqrtExp = (fieldP + BigInt.one) >> 2;
final BigInt _seven = BigInt.from(7);

BigInt _m(BigInt a) => a % fieldP;

/// A point of secp256k1 (Jacobian; z == 0 is the point at infinity).
class Point {
  const Point._(this.x, this.y, this.z);

  final BigInt x, y, z;

  static final infinity = Point._(BigInt.one, BigInt.one, BigInt.zero);

  /// The standard generator.
  static final g = Point._(
    BigInt.parse('79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798', radix: 16),
    BigInt.parse('483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8', radix: 16),
    BigInt.one,
  );

  bool get isInfinity => z == BigInt.zero;

  Point doubled() {
    if (isInfinity || y == BigInt.zero) return infinity;
    final ysq = _m(y * y);
    final s = _m(BigInt.from(4) * x * ysq);
    final mm = _m(BigInt.from(3) * x * x);
    final nx = _m(mm * mm - BigInt.two * s);
    final ny = _m(mm * (s - nx) - BigInt.from(8) * ysq * ysq);
    return Point._(nx, ny, _m(BigInt.two * y * z));
  }

  Point operator +(Point b) {
    if (isInfinity) return b;
    if (b.isInfinity) return this;
    final z1z1 = _m(z * z), z2z2 = _m(b.z * b.z);
    final u1 = _m(x * z2z2), u2 = _m(b.x * z1z1);
    final s1 = _m(y * b.z * z2z2), s2 = _m(b.y * z * z1z1);
    if (u1 == u2) return s1 == s2 ? doubled() : infinity;
    final h = _m(u2 - u1), r = _m(s2 - s1);
    final hh = _m(h * h), hhh = _m(h * hh), v = _m(u1 * hh);
    final nx = _m(r * r - hhh - BigInt.two * v);
    final ny = _m(r * (v - nx) - s1 * hhh);
    return Point._(nx, ny, _m(z * b.z * h));
  }

  Point operator -() => isInfinity ? this : Point._(x, _m(-y), z);

  Point operator -(Point b) => this + (-b);

  /// [k] times this point (any integer; reduced modulo the order).
  Point operator *(BigInt k) {
    final table = _fixed[this];
    if (table != null) return table.mul(k % curveN);
    return multiExp([this], [k]);
  }

  /// Affine (x, y), or null at infinity.
  (BigInt, BigInt)? get affine {
    if (isInfinity) return null;
    final zi = z.modInverse(fieldP);
    final zi2 = _m(zi * zi);
    return (_m(x * zi2), _m(y * zi2 * zi));
  }

  /// 33 bytes: 0x02 or 0x03 by the parity of y, then x; 33 zeros at
  /// infinity.
  Uint8List get encoded {
    final a = affine;
    if (a == null) return Uint8List(33);
    return Uint8List.fromList([a.$2.isEven ? 2 : 3, ...scalarBytes(a.$1)]);
  }

  /// The point [bytes] encode, or null if they encode none.
  static Point? decode(List<int> bytes) {
    if (bytes.length != 33) return null;
    if (bytes.every((b) => b == 0)) return infinity;
    if (bytes[0] != 2 && bytes[0] != 3) return null;
    final x = scalarOf(bytes.sublist(1));
    final p = _lift(x);
    if (p == null) return null;
    return (p.y.isEven == (bytes[0] == 2)) ? p : -p;
  }

  static Point? _lift(BigInt x) {
    if (x >= fieldP) return null;
    final cc = _m(x * x * x + _seven);
    final y = cc.modPow(_sqrtExp, fieldP);
    if (_m(y * y) != cc) return null;
    return Point._(x, y.isEven ? y : fieldP - y, BigInt.one);
  }

  /// A point nobody knows the discrete logarithm of: the first x from
  /// SHA-256 of [label] and a counter that lies on the curve.
  static Point hashToCurve(String label) {
    for (var i = 0; ; i++) {
      final h = c.sha256.convert([...label.codeUnits, ...scalarBytes(BigInt.from(i))]).bytes;
      final p = _lift(scalarOf(h));
      if (p != null) return p;
    }
  }

  @override
  bool operator ==(Object other) {
    if (other is! Point) return false;
    if (isInfinity || other.isInfinity) return isInfinity && other.isInfinity;
    // Equal in Jacobian terms: x1 z2^2 == x2 z1^2 and y1 z2^3 == y2 z1^3.
    final z1z1 = _m(z * z), z2z2 = _m(other.z * other.z);
    return _m(x * z2z2) == _m(other.x * z1z1) && _m(y * z2z2 * other.z) == _m(other.y * z1z1 * z);
  }

  @override
  int get hashCode => isInfinity ? 0 : affine!.$1.hashCode;

  /// Precomputes a table for this point, for bases used over and over.
  void fix() => _fixed[this] ??= _FixedTable(this);

  /// Tables by the very point object they were made for.
  static final _fixed = Expando<_FixedTable>('fixed base');

  /// sum(ks[i])*points[i], in one pass with 4-bit windows.
  static Point multiExp(List<Point> points, List<BigInt> ks) {
    assert(points.length == ks.length);
    final n = points.length;
    final scalars = [for (final k in ks) k % curveN];
    // 0..15 times each point.
    final tables = <List<Point>>[];
    for (final p in points) {
      final t = List<Point>.filled(16, infinity);
      t[1] = p;
      for (var i = 2; i < 16; i++) {
        t[i] = t[i - 1] + p;
      }
      tables.add(t);
    }
    var acc = infinity;
    for (var w = 63; w >= 0; w--) {
      acc = acc.doubled().doubled().doubled().doubled();
      for (var i = 0; i < n; i++) {
        final d = ((scalars[i] >> (4 * w)) & _fifteen).toInt();
        if (d != 0) acc = acc + tables[i][d];
      }
    }
    return acc;
  }
}

final _fifteen = BigInt.from(15);

/// For a fixed base: every 4-bit window's 16 multiples, so a product is 64
/// additions and no doublings.
class _FixedTable {
  _FixedTable(Point base) {
    var b = base;
    for (var w = 0; w < 64; w++) {
      final row = List<Point>.filled(16, Point.infinity);
      for (var i = 1; i < 16; i++) {
        row[i] = row[i - 1] + b;
      }
      _rows.add(row);
      b = b.doubled().doubled().doubled().doubled();
    }
  }

  final _rows = <List<Point>>[];

  Point mul(BigInt k) {
    var acc = Point.infinity;
    for (var w = 0; w < 64; w++) {
      final d = ((k >> (4 * w)) & _fifteen).toInt();
      if (d != 0) acc = acc + _rows[w][d];
    }
    return acc;
  }
}

// ---- Scalars ----

BigInt scalarOf(List<int> b) {
  var r = BigInt.zero;
  for (final x in b) {
    r = (r << 8) | BigInt.from(x);
  }
  return r;
}

Uint8List scalarBytes(BigInt v) {
  final out = Uint8List(32);
  var x = v;
  for (var i = 31; i >= 0; i--) {
    out[i] = (x & BigInt.from(0xff)).toInt();
    x = x >> 8;
  }
  return out;
}

/// A scalar from SHA-256 of [tag] and [parts] (points, scalars, bytes or
/// strings), reduced modulo the order.
BigInt hashToScalar(String tag, List<Object> parts) {
  final bytes = <int>[...c.sha256.convert(tag.codeUnits).bytes];
  for (final p in parts) {
    switch (p) {
      case Point():
        bytes.addAll(p.encoded);
      case BigInt():
        bytes.addAll(scalarBytes(p % curveN));
      case List<int>():
        bytes
          ..addAll(scalarBytes(BigInt.from(p.length)))
          ..addAll(p);
      case String():
        bytes
          ..addAll(scalarBytes(BigInt.from(p.length)))
          ..addAll(p.codeUnits);
      default:
        throw ArgumentError('cannot hash $p');
    }
  }
  return scalarOf(c.sha256.convert(bytes).bytes) % curveN;
}

/// A random nonzero scalar from a secure source.
BigInt randomScalar([Random? random]) {
  final rng = random ?? Random.secure();
  while (true) {
    final k = scalarOf(List.generate(32, (_) => rng.nextInt(256)));
    if (k > BigInt.zero && k < curveN) return k;
  }
}

BigInt scalarInverse(BigInt a) => (a % curveN).modInverse(curveN);
