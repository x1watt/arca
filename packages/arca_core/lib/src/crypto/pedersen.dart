// Pedersen commitments for private amounts: C = r·G + v·H, where r (the
// blinding) hides v and nobody knows the logarithm of H to G, so no one
// can open a commitment to two values. Commitments add up: the sum of
// what a transaction creates minus what it spends shows whether value was
// made from nothing (docs/architecture.md, 10).

import 'curve.dart';

/// The blinding base, G, with its table.
final Point blindingBase = () {
  Point.g.fix();
  return Point.g;
}();

/// The value base: a point nobody knows the logarithm of.
final Point valueBase = () {
  final h = Point.hashToCurve('arca/H');
  h.fix();
  return h;
}();

/// r·G + v·H.
Point commit(BigInt value, BigInt blinding) => blindingBase * blinding + valueBase * value;
