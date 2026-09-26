// A light client (whitepaper, section 6): what a phone runs. It keeps block
// headers only and never re-executes a block. For each header it checks
// what is cheap: the producer's signature, that it follows its parent, the
// clock, and that the mining proof's quality is under the target the
// header names (the memory-hard part of that proof is left to fraud
// proofs). It follows the chain with the most work and drops a block, and
// everything built on it, when any full node shows a valid fraud proof;
// one honest full node is enough. A header older than the fraud window
// with no proof against it is final.
//
// It reads state as entries proven against a header's state root, and can
// take a whole snapshot to become a full node without replaying history.

import 'dart:async';

import '../crypto/hex.dart';
import '../transport/link.dart';
import 'fraud.dart';
import 'mining.dart';
import 'params.dart';
import 'smt.dart';
import 'state.dart';
import 'wire.dart';

class _Known {
  _Known(this.header, this.work);
  final Header? header; // null for genesis
  final BigInt work;
  bool bad = false;
}

/// A value read from the chain, with the header it was proven against.
class ProvenEntry {
  const ProvenEntry(this.at, this.value);
  final String at;

  /// The encoded value, or null when the entry is absent.
  final String? value;
}

class LightClient {
  LightClient({
    required this.params,
    required this.genesisRoot,
    required this.genesisTick,
    required this.address,
    required this.link,
    List<String> peers = const [],
    DateTime Function()? now,
  }) : peers = {...peers}..remove(address),
       _now = now ?? DateTime.now {
    _known[''] = _Known(null, BigInt.zero);
  }

  final ChainParams params;
  final String genesisRoot;
  final int genesisTick;
  final String address;
  final MessageLink link;
  final Set<String> peers;
  final DateTime Function() _now;

  final _known = <String, _Known>{};
  final _orphans = <String, List<Header>>{};

  /// Blocks shown wrong, kept so they are never taken again.
  final rejected = <String>{};
  String _head = '';
  StreamSubscription<Inbound>? _sub;
  Timer? _timer;
  final _parts = Reassembly();
  final _waiting = <String, Completer<Map>>{};
  var _nextId = 0;
  var _turn = 0;

  void Function(String message)? log;

  int get currentTick => _now().millisecondsSinceEpoch ~/ params.tickMillis;
  String get headHash => _head;
  int get height => _known[_head]?.header?.height ?? 0;
  Header? header(String hash) => _known[hash]?.header;

  /// The newest header of the best chain that is past the fraud window.
  String get finalHash {
    var h = _head;
    while (h.isNotEmpty) {
      final k = _known[h]!;
      if (k.header!.tick + params.fraudWindowTicks <= currentTick) return h;
      h = k.header!.prev;
    }
    return '';
  }

  void start() {
    _sub = link.incoming
        .where((m) => m.to == address && m.bytes.isNotEmpty && m.bytes[0] == chainTag)
        .listen(_onInbound);
    _timer = Timer.periodic(Duration(milliseconds: params.tickMillis * params.blockTicks), (_) => _sync());
    _sync();
  }

  Future<void> stop() async {
    _timer?.cancel();
    await _sub?.cancel();
  }

  void _send(String to, Map<String, Object?> m) => unawaited(link.send(to, encodeChainMessage(m), from: address));

  /// Asks one peer in turn for headers after the newest one we share.
  void _sync() {
    if (peers.isEmpty) return;
    final peer = peers.elementAt(_turn++ % peers.length);
    final have = <String>[];
    var h = _head;
    var step = 1;
    while (h.isNotEmpty && have.length < 32) {
      have.add(h);
      for (var i = 0; i < step && h.isNotEmpty; i++) {
        h = _known[h]!.header!.prev;
      }
      if (have.length > 1) step *= 2;
    }
    _send(peer, {'t': 'get', 'have': have, 'headers': true});
  }

  void _onInbound(Inbound m) {
    final msg = _parts.add(m);
    if (msg == null) return;
    switch (msg['t']) {
      case 'header':
        _accept(Header.fromJson(msg['h'] as Map), m.from);
      case 'block':
        final b = msg['b'] as Map;
        _accept(Header(Map<String, Object?>.from(_headerFields(b)), b['sig'] as String), m.from);
      case 'fraud':
        unawaited(_onFraud((msg['f'] as Map).cast<String, Object?>()));
      case 'entry' || 'snapshot' when msg['id'] != null:
        _waiting.remove('${msg['id']}')?.complete(msg);
    }
  }

  static Map<String, Object?> _headerFields(Map b) => {
    'height': b['height'],
    'prev': b['prev'],
    'tick': b['tick'],
    'producer': b['producer'],
    'target': b['target'],
    'txRoot': b['txRoot'],
    'txCount': (b['txs'] as List).length,
    'stateRoot': b['stateRoot'],
    'traceRoot': b['traceRoot'],
    'corpusRoot': b['corpusRoot'],
    'proof': b['proof'],
  };

  void _accept(Header h, String from) {
    final hash = h.hash;
    if (_known.containsKey(hash) || rejected.contains(hash)) return;
    final parent = _known[h.prev];
    if (parent == null) {
      (_orphans[h.prev] ??= []).add(h);
      _sync();
      return;
    }
    if (parent.bad || !_check(h, parent)) return;
    final work = h.proof.isEmpty ? BigInt.one : expectedWork(h.target);
    _known[hash] = _Known(h, parent.work + work);
    _chooseHead();
    for (final child in _orphans.remove(hash) ?? const <Header>[]) {
      _accept(child, from);
    }
  }

  bool _check(Header h, _Known parent) {
    final p = parent.header;
    if (h.height != (p?.height ?? 0) + 1) return false;
    if (p != null && h.tick <= p.tick) return false;
    if (h.tick > currentTick + 2) return false; // from the future
    if (!h.signed) return false;
    if (h.proof.isNotEmpty) {
      final proof = SliceProof.fromJson(h.proof);
      if (proof.steward != h.producer) return false;
      if (h.quality >= h.target) return false;
    }
    return true;
  }

  void _chooseHead() {
    var best = '';
    for (final e in _known.entries) {
      if (e.value.bad) continue;
      final b = _known[best]!;
      if (e.value.work > b.work ||
          e.value.work == b.work &&
              e.value.header != null &&
              b.header != null &&
              e.value.header!.quality < b.header!.quality) {
        best = e.key;
      }
    }
    if (best != _head) log?.call('head ${_known[best]!.header?.height} ${best.substring(0, best.length.clamp(0, 6))}');
    _head = best;
  }

  Future<void> _onFraud(Map<String, Object?> json) async {
    final proof = FraudProof(json);
    final hash = proof.blockHash;
    if (rejected.contains(hash)) return;
    try {
      await proof.verify(params, genesisRoot: genesisRoot);
    } on Object catch (e) {
      log?.call('a fraud proof that does not hold: $e');
      return;
    }
    log?.call('block ${proof.block.height} shown wrong');
    rejected.add(hash);
    // The block and everything built on it.
    final bad = {hash};
    var grew = true;
    while (grew) {
      grew = false;
      for (final e in _known.entries) {
        final prev = e.value.header?.prev;
        if (prev != null && bad.contains(prev) && bad.add(e.key)) grew = true;
      }
    }
    for (final h in bad) {
      _known[h]?.bad = true;
      rejected.add(h);
    }
    _chooseHead();
  }

  Future<Map> _ask(String peer, Map<String, Object?> m) {
    final id = '${_nextId++}';
    final c = Completer<Map>();
    _waiting[id] = c;
    _send(peer, {...m, 'id': id});
    return c.future.timeout(
      const Duration(seconds: 20),
      onTimeout: () {
        _waiting.remove(id);
        throw TimeoutException('no answer from $peer');
      },
    );
  }

  /// Reads [keys] of [namespace] as of block [at] (the head by default)
  /// from [peer], each checked against that header's state root.
  Future<Map<String, ProvenEntry>> read(String namespace, List<String> keys, {String? at, String? peer}) async {
    final hash = at ?? _head;
    final h = _known[hash]?.header;
    final root = h?.stateRoot ?? genesisRoot;
    final answer = await _ask(peer ?? peers.first, {'t': 'entry', 'at': hash, 'ns': namespace, 'keys': keys});
    final roots = [for (final r in answer['roots'] as List) fromHex(r as String)];
    if (toHex(ChainState.stateRootOf(roots)) != root) throw StateError('the namespaces do not make the state root');
    final i = ChainState.namespaces.indexOf(namespace);
    final partial = SmtPartial.fromProofs(roots[i], [
      for (final p in answer['proofs'] as List) SmtProof.fromJson(p as Map),
    ]);
    final values = (answer['values'] as Map).cast<String, String?>();
    final out = <String, ProvenEntry>{};
    for (final k in keys) {
      final got = partial.valueHash(k);
      final v = values[k];
      if ((got == null) != (v == null) || got != null && toHex(got) != toHex(smtValueHash(v!))) {
        throw StateError('the value of $namespace/$k is not the proven one');
      }
      out[k] = ProvenEntry(hash, v);
    }
    return out;
  }

  /// The whole state after block [at] (the final block by default), every
  /// namespace checked against its root and the header's state root: what
  /// a new full node starts from instead of replaying history.
  Future<ChainState> snapshot({String? at, String? peer}) async {
    final hash = at ?? finalHash;
    final root = _known[hash]?.header?.stateRoot ?? genesisRoot;
    final entries = <String, Map<String, String>>{};
    List<String>? roots;
    for (final ns in ChainState.namespaces) {
      final got = <String, String>{};
      int? from = 0;
      while (from != null) {
        final page = await _ask(peer ?? peers.first, {'t': 'snapshot', 'at': hash, 'ns': ns, 'from': from});
        roots ??= [for (final r in page['roots'] as List) r as String];
        got.addAll((page['entries'] as Map).cast<String, String>());
        from = page['next'] as int?;
      }
      entries[ns] = got;
    }
    final rootBytes = [for (final r in roots!) fromHex(r)];
    if (toHex(ChainState.stateRootOf(rootBytes)) != root) throw StateError('the snapshot is not the header\'s state');
    for (var i = 0; i < ChainState.namespaces.length; i++) {
      if (toHex(smtRoot(entries[ChainState.namespaces[i]]!)) != roots[i]) {
        throw StateError('the snapshot of ${ChainState.namespaces[i]} does not match its root');
      }
    }
    final state = ChainState.fromEntries(params, entries);
    if (state.rootHex != root) throw StateError('the snapshot does not rebuild the state root');
    return state..head = hash;
  }
}
