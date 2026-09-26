// A chain node (whitepaper, section 6): keeps every block it has checked,
// follows the chain with the most work, gossips blocks and transactions to
// its peers over the same link as everything else, and, as a steward,
// mines each tick and posts its daily holding proofs by itself.
//
// Messages start with 0xC1 (never '[', so the Nostr side ignores them):
//   {"t":"block","b":{...}}   a block
//   {"t":"tx","tx":{...}}      a transaction
//   {"t":"get","have":[...]}  "send me your chain after the newest of
//                             these block hashes you also have"; with
//                             "headers":true, headers only (light clients)
//   {"t":"header","h":{...}}  a block header, for light clients
//   {"t":"part",...}          one part of a message too big for one
//                             datagram (fraud proofs, snapshot pages)
//   {"t":"fraud","f":{...}}   a fraud proof (fraud.dart)
//   {"t":"entry",...}         a state entry and its proof, asked or given
//   {"t":"snapshot",...}      a page of a state's entries, asked or given

import 'dart:async';
import 'dart:convert';

import '../crypto/hex.dart';
import '../transport/link.dart';
import 'block.dart';
import 'signer.dart';
import 'wire.dart';
import 'fraud.dart';
import 'mining.dart';
import 'params.dart';
import 'smt.dart';
import 'state.dart';
import 'tx.dart';

String _short(String? s) => s == null || s.length <= 6 ? '$s' : s.substring(0, 6);

/// Upper bound for a block on the wire, under the 32 KiB message limit.
const maxBlockBytes = 26 * 1024;

class _Entry {
  _Entry(this.block, this.state, this.work);
  final Block? block;
  final ChainState state;
  final BigInt work;
}

class ChainNode {
  ChainNode({
    required this.params,
    required ChainState genesis,
    required this.address,
    required this.link,
    List<int>? secretKey,
    Signer? signer,
    this.steward,
    List<String> peers = const [],
    DateTime Function()? now,
    Block? base,
    BigInt? baseWork,
    String? genesisRoot,
  }) : peers = {...peers}..remove(address),
       _now = now ?? DateTime.now,
       signer = signer ?? LocalSigner(secretKey!),
       _genesisRoot = genesisRoot ?? genesis.rootHex {
    _base = _Entry(base, genesis, baseWork ?? BigInt.zero);
    _entries[base?.hash ?? ''] = _base;
    _head = _base;
  }

  /// Where this node's chain starts: genesis, or the block of the snapshot
  /// it was restarted from ([genesis] is then the state after that block).
  late final _Entry _base;

  _Entry? _parentOf(_Entry e) => identical(e, _base) ? null : _entries[e.block!.prev];

  /// What a restart needs: the head block, its state and its work.
  Map<String, Object?> snapshot() => {
    'block': _head.block?.toJson(),
    'work': _head.work.toString(),
    'state': {for (final ns in ChainState.namespaces) ns: _head.state.entries(ns)},
  };

  /// A node restarted from [snapshot].
  static ChainNode fromSnapshot(
    Map snap, {
    required ChainParams params,
    required String genesisRoot,
    required String address,
    required MessageLink link,
    List<int>? secretKey,
    Signer? signer,
    Steward? steward,
    List<String> peers = const [],
  }) {
    final entries = {
      for (final e in (snap['state'] as Map).entries) e.key as String: (e.value as Map).cast<String, String>(),
    };
    final block = snap['block'] == null ? null : Block.fromJson(snap['block'] as Map);
    return ChainNode(
      params: params,
      genesis: ChainState.fromEntries(params, entries),
      address: address,
      link: link,
      secretKey: secretKey,
      signer: signer,
      steward: steward,
      peers: peers,
      base: block,
      baseWork: BigInt.parse(snap['work'] as String),
      genesisRoot: genesisRoot,
    );
  }

  final ChainParams params;
  final String address;
  final MessageLink link;

  /// Signs this node's transactions and blocks.
  final Signer signer;
  late final String key = signer.publicKey;

  /// This node's packed partitions, when it keeps any.
  Steward? steward;
  final Set<String> peers;
  final DateTime Function() _now;

  final _entries = <String, _Entry>{};
  late _Entry _head;
  final _mempool = <String, Tx>{};
  final _orphans = <String, List<Block>>{};
  StreamSubscription<Inbound>? _sub;
  Timer? _timer;
  bool _busy = false;

  /// While false the node follows the chain and relays, but does not mine.
  bool mining = true;

  /// The anchor this node posts for a circle it administers or moderates
  /// (normally [CircleLog.anchorBody]); null to skip that circle.
  Map<String, Object?>? Function(String circle)? anchorBody;

  /// Diagnostics: rejected blocks, orphans, forks switched.
  void Function(String message)? log;

  /// Called whenever the head changes.
  void Function(ChainState head)? onHead;

  ChainState get state => _head.state;
  String get headHash => _head.block?.hash ?? '';
  int get currentTick => _now().millisecondsSinceEpoch ~/ params.tickMillis;

  void start() {
    _sub = link.incoming
        .where((m) => m.to == address && m.bytes.isNotEmpty && m.bytes[0] == chainTag)
        .listen(_onInbound);
    _timer = Timer.periodic(Duration(milliseconds: params.tickMillis), (_) => _onTick());
    for (final p in peers) {
      _askChain(p);
    }
  }

  Future<void> stop() async {
    _timer?.cancel();
    await _sub?.cancel();
  }

  // ---- Transactions ----

  /// The nonce for this node's next transaction, counting those waiting.
  int nextNonce() =>
      (state.nonces[key] ?? 0) + _mempool.values.where((t) => t.from == key && TxType.numbered(t.type)).length;

  /// Signs and submits a transaction from this node's key.
  Future<Tx> submit(String type, Map<String, Object?> body) {
    // Signing may go to another isolate: one submission at a time, so each
    // takes the next nonce.
    final done = _submitting.then((_) async {
      final tx = await Tx.signWith(signer, type, TxType.numbered(type) ? nextNonce() : 0, body);
      _addTx(tx, null);
      return tx;
    });
    _submitting = done.then((_) {}, onError: (Object _) {});
    return done;
  }

  Future<void> _submitting = Future.value();

  void _addTx(Tx tx, String? from) {
    if (_mempool.containsKey(tx.id) || !tx.verify()) return;
    if (_stale(tx, state)) return;
    _mempool[tx.id] = tx;
    _broadcast({'t': 'tx', 'tx': tx.toJson()}, except: from);
  }

  /// Whether [tx] can no longer go into a block on top of [s]: its nonce
  /// is used, or it is a holding proof for another day or already counted.
  static bool _stale(Tx tx, ChainState s) {
    if (TxType.numbered(tx.type)) return tx.nonce < (s.nonces[tx.from] ?? 0);
    final p = (tx.body['proof'] as Map?)?['partition'];
    return tx.body['day'] != s.day || s.provenOn[tx.from]?[p] == s.day;
  }

  int _relayedAt = 0;

  /// Once per block interval, asks a peer for news and sends the waiting
  /// transactions again: a message can be lost (a new I2P tunnel drops the
  /// first ones), and a transaction in a block that lost a fork is known
  /// only to its sender. Without this, a steward whose `declare` never
  /// reached a miner can never mine its way in.
  void _resync(int tick) {
    if (tick - _relayedAt < params.blockTicks) return;
    _relayedAt = tick;
    // A lost block message heals here too: ask one peer in turn for
    // anything after our head.
    if (peers.isNotEmpty) _askChain(peers.elementAt(_syncTurn++ % peers.length));
    for (final t in _mempool.values.take(64)) {
      _broadcast({'t': 'tx', 'tx': t.toJson()});
    }
  }

  // ---- Blocks ----

  Future<void> _accept(Block b, String? from) async {
    final hash = b.hash;
    if (_entries.containsKey(hash)) return;
    if (b.tick > currentTick + 2) return; // from the future
    final parent = _entries[b.prev];
    if (parent == null) {
      (_orphans[b.prev] ??= []).add(b);
      log?.call('orphan ${b.height} ${_short(hash)} from ${_short(from)}');
      if (from != null) _askChain(from);
      return;
    }
    final ChainState next;
    try {
      next = await b.applyTo(parent.state);
    } on ChainError catch (e) {
      log?.call('rejected block ${b.height} ${_short(hash)} from ${_short(from)}: $e');
      unawaited(_proveFraud(parent, b));
      return;
    }
    // Work is what the target asked for, not what the proof happened to
    // reach: one lucky block must not outweigh a longer chain.
    final work = b.proof.isEmpty ? BigInt.one : expectedWork(parent.state.target);
    final entry = _Entry(b, next, parent.work + work);
    _entries[hash] = entry;
    if (_better(entry, _head)) {
      final dropped = _abandoned(_head, entry);
      if (b.prev != headHash) {
        log?.call('switched to fork at ${b.height} ${_short(hash)}, ${dropped.length} txs back');
      }
      _head = entry;
      for (final t in dropped) {
        _mempool[t.id] = t;
      }
      _mempool.removeWhere((_, t) => _stale(t, next));
      onHead?.call(next);
    }
    _broadcastBlock(b, except: from);
    for (final child in _orphans.remove(hash) ?? const <Block>[]) {
      await _accept(child, from);
    }
  }

  /// Whether [a] is a better head than [b]: more work, or as much work and
  /// a better proof at the tip, which every node judges alike and nobody
  /// can grind, so forks of equal weight settle on the same side.
  static bool _better(_Entry a, _Entry b) {
    if (a.work != b.work) return a.work > b.work;
    if (a.block == null || b.block == null) return false;
    return a.block!.quality < b.block!.quality;
  }

  /// Transactions in the blocks of [from] that are not on the chain to
  /// [to]: when the head moves to another fork they go back to the mempool.
  List<Tx> _abandoned(_Entry from, _Entry to) {
    int height(_Entry e) => e.block?.height ?? 0;
    _Entry parent(_Entry e) => _parentOf(e)!;
    final txs = <Tx>[];
    var old = from, now = to;
    while (height(now) > height(old)) {
      now = parent(now);
    }
    while (old != now) {
      if (height(old) >= height(now)) {
        txs.addAll(old.block!.txs);
        old = parent(old);
      } else {
        now = parent(now);
      }
    }
    return txs;
  }

  var _syncTurn = 0;
  final _askedAt = <String, int>{};

  /// Asks [peer] for its chain after the newest block both have: the
  /// locator names our head, then blocks 1, 2, 4, 8... below it.
  void _askChain(String peer) {
    // One request per peer per tick: a burst of orphans asks once.
    final tick = currentTick;
    if (_askedAt[peer] == tick) return;
    _askedAt[peer] = tick;
    final have = <String>[];
    _Entry? e = _head;
    var step = 1;
    while (e != null && e.block != null && have.length < 32) {
      have.add(e.block!.hash);
      for (var i = 0; i < step && e != null; i++) {
        e = _parentOf(e);
      }
      if (have.length > 1) step *= 2;
    }
    _send(peer, {'t': 'get', 'have': have});
  }

  /// The height after the newest of [have] on the current chain (1 when
  /// none is: send from the start).
  int _after(List<String> have) {
    for (final h in have) {
      final e = _entries[h];
      if (e?.block == null) continue;
      _Entry? c = _head;
      while (c != null && c.block != null && c.block!.height > e!.block!.height) {
        c = _parentOf(c);
      }
      if (identical(c, e)) return e!.block!.height + 1;
    }
    return 1;
  }

  /// Blocks of the current chain from [height] on, oldest first.
  List<Block> chainFrom(int height) {
    final list = <Block>[];
    _Entry? e = _head;
    while (e != null && e.block != null && e.block!.height >= height) {
      list.add(e.block!);
      e = _parentOf(e);
    }
    return list.reversed.toList();
  }

  // ---- The tick: mine, and keep up with holding proofs ----

  Future<void> _onTick() async {
    if (_busy) return;
    _busy = true;
    try {
      final tick = currentTick;
      _resync(tick);
      if (!mining || tick <= state.tick) return;
      final head = state;
      final mine = steward == null ? const <int, String>{} : (head.declarations[key] ?? const <int, String>{});
      _holdingProofs(head, mine, tick);
      _anchor(head, tick);
      final needsProof = head.corpusRoot.isNotEmpty && head.stewards > 0;
      Map<String, Object?> proof = const {};
      if (needsProof) {
        if (mine.isEmpty) return;
        // One read per declared partition: the best slice this tick.
        final challenge = mineChallenge(headHash, tick);
        int? best;
        BigInt? bestQuality;
        for (final p in mine.keys) {
          final (_, _, packed) = await steward!.read(challenge, p);
          final q = proofQuality(challenge, key, packed);
          if (bestQuality == null || q < bestQuality) {
            best = p;
            bestQuality = q;
          }
        }
        if (bestQuality == null || bestQuality >= head.target) return;
        proof = (await steward!.prove(challenge, best!, mine[best]!)).toJson();
      } else if (_mempool.isEmpty) {
        return; // before anyone mines, blocks only carry transactions
      }
      final txs = _pick();
      final block = await Block.produceWith(head, signer, txs, tick: tick, proof: proof);
      if (headHash == block.prev) await _accept(block, null);
    } catch (e) {
      // A slice this steward cannot read or prove: no block this tick.
      log?.call('no block this tick: $e');
      return;
    } finally {
      _busy = false;
    }
  }

  /// Waiting transactions in nonce order, up to what fits in one message.
  List<Tx> _pick() {
    final txs = _mempool.values.toList()
      ..sort((a, b) => a.from != b.from ? a.from.compareTo(b.from) : a.nonce.compareTo(b.nonce));
    final out = <Tx>[];
    var size = 4096;
    for (final t in txs) {
      final n = utf8.encode(jsonEncode(t.toJson())).length + 70; // and its trace root
      if (size + n > maxBlockBytes) break;
      out.add(t);
      size += n;
    }
    return out;
  }

  /// Anchors each circle this node may anchor about once per
  /// [ChainParams.anchorTicks], so it keeps earning.
  void _anchor(ChainState head, int tick) {
    final body = anchorBody;
    if (body == null) return;
    for (final e in head.circles.entries) {
      if (!e.value.mayAnchor(key) || tick - e.value.anchoredAt < params.anchorTicks) continue;
      final waiting = _mempool.values.any((t) => t.type == TxType.anchor && t.from == key && t.body['circle'] == e.key);
      if (waiting) continue;
      final b = body(e.key);
      if (b != null) submit(TxType.anchor, {...b, 'circle': e.key});
    }
  }

  final _proving = <String>{};

  /// Posts today's holding proof for each partition this steward declared
  /// before today, once.
  void _holdingProofs(ChainState head, Map<int, String> mine, int tick) {
    if (mine.isEmpty || head.beacon.isEmpty && head.day == 0) return;
    final day = head.day;
    final since = head.declaredOn[key] ?? const {};
    final proven = head.provenOn[key] ?? const {};
    for (final e in mine.entries) {
      final p = e.key;
      if ((since[p] ?? day) >= day || proven[p] == day) continue;
      // Keyed by beacon too: after a switch to another fork the day's
      // challenge changes and the proof must be made again.
      final id = '$day:$p:${head.beacon}';
      if (!_proving.add(id)) continue;
      unawaited(
        steward!
            .prove(holdChallenge(head.beacon, day, key, p), p, e.value)
            .then<void>((proof) {
              submit(TxType.holdingProof, {'day': day, 'proof': proof.toJson()});
            })
            .catchError((Object _) {}),
      );
    }
  }

  // ---- Network ----

  void _send(String to, Map<String, Object?> m) => unawaited(link.send(to, encodeChainMessage(m), from: address));

  void _broadcast(Map<String, Object?> m, {String? except}) {
    for (final p in peers) {
      if (p != except) _send(p, m);
    }
  }

  // ---- Light clients ----

  /// Peers that follow headers only.
  final lightPeers = <String>{};
  final _proven = <String>{};

  void _broadcastBlock(Block b, {String? except}) {
    for (final p in peers) {
      if (p == except) continue;
      _send(p, lightPeers.contains(p) ? {'t': 'header', 'h': Header.of(b).toJson()} : {'t': 'block', 'b': b.toJson()});
    }
  }

  /// Shows everyone why [b] is wrong, when a fraud proof can show it.
  Future<void> _proveFraud(_Entry parent, Block b) async {
    if (!_proven.add(b.hash)) return;
    final parentHeader = parent.block == null ? null : Header.of(parent.block!);
    final proof = await FraudProof.build(parent.state, parentHeader, b);
    if (proof == null) return;
    log?.call('fraud proof for ${b.height} ${_short(b.hash)}');
    for (final p in peers) {
      _sendLarge(p, {'t': 'fraud', 'f': proof.json});
    }
  }

  /// Passes on to light clients a fraud proof this node has not seen,
  /// once it holds.
  Future<void> _relayFraud(String from, Map msg) async {
    final proof = FraudProof((msg['f'] as Map).cast<String, Object?>());
    if (!_proven.add(proof.blockHash)) return;
    try {
      await proof.verify(params, genesisRoot: _genesisRoot);
    } on Object {
      return;
    }
    for (final p in lightPeers) {
      if (p != from) _sendLarge(p, {'t': 'fraud', 'f': proof.json});
    }
  }

  final String _genesisRoot;

  /// Answers to requests this node does not know (the testnet spec, a
  /// circle's log): null to stay silent.
  Future<Map<String, Object?>?> Function(String from, Map msg)? answer;

  /// The state after block [at] as it was committed (head '').
  ChainState? _committed(String at) => _entries[at]?.state.copy()?..head = '';

  void _answerEntry(String to, Map msg) {
    final at = msg['at'] as String? ?? '', ns = msg['ns'] as String? ?? '';
    final state = _committed(at);
    if (state == null || !ChainState.namespaces.contains(ns)) return;
    final entries = state.entries(ns);
    final tree = SmtTree(entries);
    final keys = [for (final k in msg['keys'] as List? ?? const []) '$k'].take(32);
    _sendLarge(to, {
      't': 'entry',
      'id': msg['id'],
      'at': at,
      'ns': ns,
      'roots': [for (final r in state.namespaceRoots()) toHex(r)],
      'values': {for (final k in keys) k: entries[k]},
      'proofs': [for (final k in keys) tree.prove(k).toJson()],
    });
  }

  void _answerSnapshot(String to, Map msg) {
    final at = msg['at'] as String? ?? '', ns = msg['ns'] as String? ?? '';
    final state = _committed(at);
    if (state == null || !ChainState.namespaces.contains(ns)) return;
    final entries = state.entries(ns);
    final keys = entries.keys.toList()..sort();
    final from = msg['from'] as int? ?? 0;
    final page = <String, String>{};
    var size = 0, i = from;
    for (; i < keys.length && size < 16 * 1024; i++) {
      page[keys[i]] = entries[keys[i]]!;
      size += keys[i].length + entries[keys[i]]!.length;
    }
    _sendLarge(to, {
      't': 'snapshot',
      'id': msg['id'],
      'at': at,
      'ns': ns,
      'from': from,
      'next': i < keys.length ? i : null,
      'entries': page,
      'roots': [for (final r in state.namespaceRoots()) toHex(r)],
    });
  }

  void _onInbound(Inbound m) {
    final Map? whole = _parts.add(m);
    if (whole == null) return;
    _onMessage(m.from, whole);
  }

  final _parts = Reassembly();

  void _sendLarge(String to, Map<String, Object?> m) {
    for (final part in Reassembly.split(m)) {
      _send(to, part);
    }
  }

  static const _known = {'block', 'tx', 'get', 'header', 'fraud', 'entry', 'snapshot', 'part'};

  /// Transactions waiting to go into a block.
  Iterable<Tx> get waiting => _mempool.values;

  /// The number of peers this node has heard from or been told of.
  int get peerCount => peers.length;

  void _onMessage(String from, Map msg) {
    if (msg['t'] == 'get' && msg['headers'] == true) lightPeers.add(from);
    peers.add(from);
    switch (msg['t']) {
      case 'block':
        unawaited(_accept(Block.fromJson(msg['b'] as Map), from));
      case 'tx':
        _addTx(Tx.fromJson(msg['tx'] as Map), from);
      case 'get':
        final have = [for (final h in msg['have'] as List? ?? const []) '$h'];
        for (final b in chainFrom(_after(have)).take(64)) {
          _send(
            from,
            msg['headers'] == true ? {'t': 'header', 'h': Header.of(b).toJson()} : {'t': 'block', 'b': b.toJson()},
          );
        }
      case 'fraud':
        unawaited(_relayFraud(from, msg));
      case final String t when !_known.contains(t) && answer != null:
        unawaited(
          answer!(from, msg).then((reply) {
            if (reply != null) _sendLarge(from, {...reply, 'id': msg['id']});
          }),
        );
      case 'entry' when msg['keys'] != null:
        _answerEntry(from, msg);
      case 'snapshot' when msg['entries'] == null:
        _answerSnapshot(from, msg);
    }
  }
}
