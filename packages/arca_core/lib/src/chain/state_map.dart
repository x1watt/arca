// The maps the chain's state is made of. Each is one namespace of the
// state commitment (a sparse Merkle tree over its entries, smt.dart) and
// can, besides holding values:
//
// - remember which keys a step touched, and whether it went through the
//   whole map, so a full node knows what a fraud proof must carry;
// - refuse keys it was not given, so a verifier holding only witnessed
//   entries notices a proof that left out something the step needs;
// - keep its root until something touches it. So a value held in the map
//   (a circle, a nested map) is changed only right after it was read
//   through the map, never through a reference kept across a root.

import 'dart:collection';
import 'dart:typed_data';

import 'smt.dart';

/// A step needed an entry the proof did not carry.
class Unwitnessed implements Exception {
  const Unwitnessed(this.namespace, this.key);
  final String namespace;

  /// '*' when the step went through the whole namespace.
  final String key;
  @override
  String toString() => 'the proof does not carry $namespace/$key';
}

/// What a step touched, shared by a state and the copies made from it.
class Touched {
  final keys = <String>{};
  bool all = false;
}

class StateMap<V> extends MapBase<String, V> {
  StateMap(this.namespace);

  final String namespace;
  final _m = <String, V>{};

  /// Keys this map may use; null when it holds the whole namespace.
  Set<String>? witnessed;

  /// While not null, collects what is touched.
  Touched? touched;

  Uint8List? _root;

  void _key(Object? key) {
    _root = null;
    touched?.keys.add(key as String);
    if (witnessed != null && !witnessed!.contains(key)) throw Unwitnessed(namespace, '$key');
  }

  void _all() {
    _root = null;
    touched?.all = true;
    if (witnessed != null) throw Unwitnessed(namespace, '*');
  }

  @override
  V? operator [](Object? key) {
    _key(key);
    return _m[key];
  }

  @override
  void operator []=(String key, V value) {
    _key(key);
    _m[key] = value;
  }

  @override
  bool containsKey(Object? key) {
    _key(key);
    return _m.containsKey(key);
  }

  @override
  V? remove(Object? key) {
    _key(key);
    return _m.remove(key);
  }

  @override
  void clear() {
    _all();
    _m.clear();
  }

  @override
  Iterable<String> get keys {
    _all();
    return _m.keys;
  }

  @override
  int get length {
    _all();
    return _m.length;
  }

  /// The values without touching anything (for copies and commitments).
  Map<String, V> get raw => _m;

  /// Starts recording what the next step touches.
  void track() => touched = Touched();

  /// The namespace's root over [encode]d values, cached until touched.
  Uint8List root(String Function(V) encode) => _root ??= smtRoot({for (final e in _m.entries) e.key: encode(e.value)});

  /// Copies values, and the cached root, into [to].
  void copyInto(StateMap<V> to, V Function(V) copy) {
    for (final e in _m.entries) {
      to._m[e.key] = copy(e.value);
    }
    to
      .._root = _root
      ..witnessed = witnessed
      ..touched = touched;
  }
}
