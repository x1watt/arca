// Binary Merkle trees over SHA-256, with leaf and node hashes kept apart
// (a leaf can never pass for a node). Used for chunks (1 KB slices),
// partitions (chunks), the corpus (partitions), the state and blocks.

import 'dart:typed_data';

import 'package:crypto/crypto.dart' as c;

Uint8List _h(int tag, List<int> a, [List<int>? b]) {
  final bytes = BytesBuilder(copy: false)
    ..addByte(tag)
    ..add(a);
  if (b != null) bytes.add(b);
  return Uint8List.fromList(c.sha256.convert(bytes.takeBytes()).bytes);
}

Uint8List leafHash(List<int> data) => _h(0, data);
Uint8List nodeHash(List<int> left, List<int> right) => _h(1, left, right);

/// Root of [leaves] (already hashed). An odd node is carried up unchanged;
/// the root of nothing is 32 zero bytes.
Uint8List merkleRoot(List<Uint8List> leaves) {
  if (leaves.isEmpty) return Uint8List(32);
  var level = leaves;
  while (level.length > 1) {
    final next = <Uint8List>[];
    for (var i = 0; i < level.length; i += 2) {
      next.add(i + 1 < level.length ? nodeHash(level[i], level[i + 1]) : level[i]);
    }
    level = next;
  }
  return level.single;
}

/// One step of a path: the sibling hash and whether it sits on the right.
typedef ProofStep = (Uint8List sibling, bool right);

/// The path from leaf [index] to the root.
List<ProofStep> merkleProof(List<Uint8List> leaves, int index) {
  final path = <ProofStep>[];
  var level = leaves;
  var i = index;
  while (level.length > 1) {
    final pair = i ^ 1;
    if (pair < level.length) path.add((level[pair], pair > i));
    final next = <Uint8List>[];
    for (var k = 0; k < level.length; k += 2) {
      next.add(k + 1 < level.length ? nodeHash(level[k], level[k + 1]) : level[k]);
    }
    level = next;
    i ~/= 2;
  }
  return path;
}

bool merkleVerify(Uint8List leaf, List<ProofStep> path, Uint8List root) {
  var h = leaf;
  for (final (sibling, right) in path) {
    h = right ? nodeHash(h, sibling) : nodeHash(sibling, h);
  }
  return _eq(h, root);
}

bool _eq(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var d = 0;
  for (var i = 0; i < a.length; i++) {
    d |= a[i] ^ b[i];
  }
  return d == 0;
}

/// Like [merkleVerify], but also checks that [path] is the path of leaf
/// [index] in a tree of [count] leaves, so a proof cannot claim one
/// position and show another.
bool merkleVerifyAt(Uint8List leaf, int index, int count, List<ProofStep> path, Uint8List root) =>
    _expectedSides(index, count, path.length) && merkleVerify(leaf, path, root);

bool _expectedSides(int index, int count, int steps) {
  if (index < 0 || index >= count) return false;
  var n = count, i = index, k = 0;
  while (n > 1) {
    final pair = i ^ 1;
    if (pair < n) k++;
    n = (n + 1) ~/ 2;
    i ~/= 2;
  }
  return k == steps;
}

/// Computes the root a path leads to from [leaf] at [index] of [count]
/// leaves, or null when the path does not fit that position.
Uint8List? merkleClimb(Uint8List leaf, int index, int count, List<ProofStep> path) {
  if (index < 0 || index >= count) return null;
  var h = leaf, n = count, i = index, k = 0;
  while (n > 1) {
    final pair = i ^ 1;
    if (pair < n) {
      if (k >= path.length) return null;
      final (sibling, right) = path[k++];
      if (right != (pair > i)) return null;
      h = right ? nodeHash(h, sibling) : nodeHash(sibling, h);
    }
    n = (n + 1) ~/ 2;
    i ~/= 2;
  }
  return k == path.length ? h : null;
}
