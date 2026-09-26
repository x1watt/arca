// A compact sparse Merkle tree: the commitment behind the chain's state,
// so any single entry, or its absence, can be proven with about log2(n)
// hashes, and a verifier holding only some entries can apply changes to
// them and compute the new root (fraud proofs, docs/architecture.md 10).
//
// Each key sits at the path SHA-256(key), read bit by bit from the top. A
// subtree with no entry hashes to 32 zero bytes; a subtree with exactly one
// entry is that entry's leaf, wherever it sits; any other subtree is an
// inner node over its two halves. So the shape depends only on the keys,
// never on the order they were added.
//
//   leaf  = SHA-256(0x00 | path | SHA-256(value))
//   inner = SHA-256(0x01 | left | right)

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as c;

import '../crypto/hex.dart';

final Uint8List smtEmpty = Uint8List(32);

Uint8List _sha(List<int> b) => Uint8List.fromList(c.sha256.convert(b).bytes);

Uint8List smtPath(String key) => _sha(utf8.encode(key));
Uint8List smtValueHash(String value) => _sha(utf8.encode(value));

Uint8List smtLeaf(Uint8List path, Uint8List valueHash) => _sha([0, ...path, ...valueHash]);
Uint8List smtInner(Uint8List left, Uint8List right) => _sha([1, ...left, ...right]);

bool _bit(Uint8List path, int depth) => (path[depth >> 3] >> (7 - (depth & 7))) & 1 == 1;

bool _eq(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// The root over [entries] (key to value).
Uint8List smtRoot(Map<String, String> entries) {
  final items = [for (final e in entries.entries) (smtPath(e.key), smtValueHash(e.value))];
  return _build(items, 0);
}

Uint8List _build(List<(Uint8List, Uint8List)> items, int depth) {
  if (items.isEmpty) return smtEmpty;
  if (items.length == 1) return smtLeaf(items[0].$1, items[0].$2);
  final left = <(Uint8List, Uint8List)>[], right = <(Uint8List, Uint8List)>[];
  for (final i in items) {
    (_bit(i.$1, depth) ? right : left).add(i);
  }
  return smtInner(_build(left, depth + 1), _build(right, depth + 1));
}

/// A sibling on the way down: its hash, and its path and value hash when
/// it is a single leaf (a verifier needs that to collapse the tree after a
/// deletion).
class SmtSibling {
  const SmtSibling(this.hash, [this.leafPath, this.leafValue]);
  final Uint8List hash;
  final Uint8List? leafPath;
  final Uint8List? leafValue;

  List<Object> toJson() => [
    toHex(hash),
    if (leafPath != null) toHex(leafPath!),
    if (leafValue != null) toHex(leafValue!),
  ];

  factory SmtSibling.fromJson(List j) => SmtSibling(
    fromHex(j[0] as String),
    j.length > 2 ? fromHex(j[1] as String) : null,
    j.length > 2 ? fromHex(j[2] as String) : null,
  );
}

/// The way from the root down to where [key] is or would be: the siblings,
/// top first, and what ends the way (nothing, or the one leaf there, which
/// is [key]'s own leaf when it is present).
class SmtProof {
  const SmtProof(this.key, this.siblings, {this.endPath, this.endValue});
  final String key;
  final List<SmtSibling> siblings;
  final Uint8List? endPath;
  final Uint8List? endValue;

  Map<String, Object?> toJson() => {
    'key': key,
    'siblings': [for (final s in siblings) s.toJson()],
    if (endPath != null) 'end': [toHex(endPath!), toHex(endValue!)],
  };

  factory SmtProof.fromJson(Map m) {
    final end = m['end'] as List?;
    return SmtProof(
      m['key'] as String,
      [for (final s in m['siblings'] as List) SmtSibling.fromJson(s as List)],
      endPath: end == null ? null : fromHex(end[0] as String),
      endValue: end == null ? null : fromHex(end[1] as String),
    );
  }
}

/// A whole tree held in memory: the full node's side, which proves keys.
class SmtTree {
  SmtTree(Map<String, String> entries)
    : _items = [for (final e in entries.entries) (smtPath(e.key), smtValueHash(e.value))];

  final List<(Uint8List, Uint8List)> _items;

  Uint8List get root => _build(_items, 0);

  SmtProof prove(String key) {
    final path = smtPath(key);
    var items = _items;
    final siblings = <SmtSibling>[];
    var depth = 0;
    while (items.length > 1) {
      final left = <(Uint8List, Uint8List)>[], right = <(Uint8List, Uint8List)>[];
      for (final i in items) {
        (_bit(i.$1, depth) ? right : left).add(i);
      }
      final (mine, other) = _bit(path, depth) ? (right, left) : (left, right);
      siblings.add(
        other.length == 1
            ? SmtSibling(smtLeaf(other[0].$1, other[0].$2), other[0].$1, other[0].$2)
            : SmtSibling(_build(other, depth + 1)),
      );
      items = mine;
      depth++;
    }
    return items.isEmpty
        ? SmtProof(key, siblings)
        : SmtProof(key, siblings, endPath: items[0].$1, endValue: items[0].$2);
  }
}

class SmtError implements Exception {
  const SmtError(this.message);
  final String message;
  @override
  String toString() => message;
}

sealed class _Node {
  Uint8List get hash;
}

class _Empty extends _Node {
  @override
  Uint8List get hash => smtEmpty;
}

class _Leaf extends _Node {
  _Leaf(this.path, this.value);
  final Uint8List path;
  final Uint8List value;
  @override
  Uint8List get hash => smtLeaf(path, value);
}

/// A subtree known only by its hash (with two entries or more below).
class _Opaque extends _Node {
  _Opaque(this.hash);
  @override
  final Uint8List hash;
}

class _Inner extends _Node {
  _Inner(this.left, this.right);
  _Node left, right;
  @override
  Uint8List get hash => smtInner(left.hash, right.hash);
}

/// The verifier's side: only the ways down to some keys, checked against a
/// root, then read and changed; [root] is then the root of the whole tree.
/// Reading or changing a key whose way was not proven throws [SmtError].
class SmtPartial {
  SmtPartial._(this._top);

  _Node _top;

  /// Checks every proof against [root] and joins them.
  factory SmtPartial.fromProofs(Uint8List root, Iterable<SmtProof> proofs) {
    _Node? top;
    for (final p in proofs) {
      final n = _fromProof(p);
      if (!_eq(n.hash, root)) throw SmtError('the proof for "${p.key}" does not lead to the root');
      top = top == null ? n : _merge(top, n);
    }
    return SmtPartial._(top ?? (_eq(root, smtEmpty) ? _Empty() : _Opaque(root)));
  }

  static _Node _fromProof(SmtProof p) {
    final path = smtPath(p.key);
    if (p.endPath != null && p.endPath!.length == 32) {
      // The leaf that ends the way must lie on it.
      for (var d = 0; d < p.siblings.length; d++) {
        if (_bit(p.endPath!, d) != _bit(path, d)) throw SmtError('the leaf in the proof for "${p.key}" is off its way');
      }
    }
    _Node n = p.endPath == null ? _Empty() : _Leaf(p.endPath!, p.endValue!);
    if (p.siblings.isNotEmpty && n is _Leaf && p.siblings.every((s) => _eq(s.hash, smtEmpty))) {
      throw SmtError('a lone leaf cannot sit below empty siblings');
    }
    for (var d = p.siblings.length - 1; d >= 0; d--) {
      final s = p.siblings[d];
      final _Node sib = s.leafPath != null
          ? _Leaf(s.leafPath!, s.leafValue!)
          : _eq(s.hash, smtEmpty)
          ? _Empty()
          : _Opaque(s.hash);
      if (s.leafPath != null && !_eq(sib.hash, s.hash)) throw SmtError('a sibling leaf does not match its hash');
      n = _bit(path, d) ? _Inner(sib, n) : _Inner(n, sib);
    }
    return n;
  }

  static _Node _merge(_Node a, _Node b) {
    if (a is _Opaque) return b;
    if (b is _Opaque) return a;
    if (a is _Inner && b is _Inner) return _Inner(_merge(a.left, b.left), _merge(a.right, b.right));
    return a;
  }

  Uint8List get root => _top.hash;

  /// The value hash at [key], or null when it is absent.
  Uint8List? valueHash(String key) {
    final path = smtPath(key);
    var n = _top;
    var d = 0;
    while (true) {
      switch (n) {
        case _Empty():
          return null;
        case _Leaf(path: final p, value: final v):
          return _eq(p, path) ? v : null;
        case _Opaque():
          throw SmtError('"$key" was not proven');
        case _Inner(:final left, :final right):
          n = _bit(path, d++) ? right : left;
      }
    }
  }

  /// Sets [key] to [value], or removes it when [value] is null.
  void put(String key, String? value) {
    final path = smtPath(key);
    _top = _put(_top, path, value == null ? null : smtValueHash(value), 0, key);
  }

  _Node _put(_Node n, Uint8List path, Uint8List? value, int d, String key) {
    switch (n) {
      case _Opaque():
        throw SmtError('"$key" was not proven');
      case _Empty():
        return value == null ? n : _Leaf(path, value);
      case _Leaf(path: final p):
        if (_eq(p, path)) return value == null ? _Empty() : _Leaf(path, value);
        if (value == null) return n;
        // Two leaves: split until their ways part.
        return _split(n, _Leaf(path, value), d);
      case _Inner():
        if (_bit(path, d)) {
          n.right = _put(n.right, path, value, d + 1, key);
        } else {
          n.left = _put(n.left, path, value, d + 1, key);
        }
        // A subtree left with one leaf and nothing else becomes that leaf.
        final (l, r) = (n.left, n.right);
        if (l is _Empty && r is _Empty) return _Empty();
        if (l is _Empty && r is _Leaf) return r;
        if (r is _Empty && l is _Leaf) return l;
        return n;
    }
  }

  static _Node _split(_Leaf a, _Leaf b, int d) {
    final ba = _bit(a.path, d), bb = _bit(b.path, d);
    if (ba == bb) {
      final below = _split(a, b, d + 1);
      return ba ? _Inner(_Empty(), below) : _Inner(below, _Empty());
    }
    return ba ? _Inner(b, a) : _Inner(a, b);
  }
}
