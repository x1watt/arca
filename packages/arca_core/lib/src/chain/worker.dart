// The chain's own isolate (docs/performance.md, 3.15): checking a block or
// a holding proof costs an Argon2id, and packing a partition costs one per
// chunk, so none of it runs on the core isolate. The core forwards chain
// messages (first byte 0xC1) between the network and this isolate, sends
// it commands, and keeps the latest state it reports for the UI.
//
// One member per profile that takes part: its chain node on the profile's
// I2P address, its keeper (packed partitions), and for the admin the
// circle's log. Each member keeps, in its folder, a snapshot of the chain
// to restart from and, for an admin, the log.
//
//   core to worker:  ['cmd', id, name, args]  ['in', from, to, bytes]
//                    ['signed', id, signature]
//   worker to core:  ['reply', id, result]  ['send', to, bytes, from]
//                    ['state', profileId, state or null]
//                    ['sign', id, profileId, message]
//
// Secret keys never come here (docs/architecture.md, 3.5 and 7): the
// worker asks the core for each signature.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' show max;
import 'dart:typed_data';

import '../crypto/curve.dart' show Point;
import '../crypto/hex.dart';
import '../transport/link.dart';
import 'archive.dart';
import 'circle_log.dart';
import 'corpus.dart';
import 'fraud.dart' show Header;
import 'smt.dart' show smtRoot;
import 'light.dart';
import 'signer.dart';
import 'state.dart';
import 'mining.dart';
import 'node.dart';
import 'params.dart';
import 'rewards.dart' show lapsed, standingOf, syncScoreOf;
import 'testnet.dart';
import 'private_tx.dart';
import 'tx.dart';
import 'verify.dart';
import 'wallet.dart';
import 'wallet_keys.dart';
import 'wire.dart';

/// Entry point of the chain isolate; [toCore] receives the worker's port
/// first.
Future<void> chainWorkerMain(SendPort toCore) async {
  final inbox = ReceivePort();
  toCore.send(inbox.sendPort);
  final w = ChainWorker((m) => toCore.send(m));
  await for (final msg in inbox) {
    final m = msg as List;
    if (m[0] == 'stop') {
      await w.stop();
      toCore.send(['stopped']);
      inbox.close();
      break;
    }
    w.receive(m);
  }
}

class _ProxyLink implements MessageLink {
  _ProxyLink(this._out);
  final void Function(List<Object?>) _out;
  final _in = StreamController<Inbound>.broadcast();

  @override
  Stream<Inbound> get incoming => _in.stream;

  @override
  Future<bool> send(String to, Uint8List bytes, {required String from}) async {
    _out(['send', to, bytes, from]);
    return true;
  }
}

/// Asks the core to sign as [profile]: ['sign', id, profile, message],
/// answered with ['signed', id, signature].
class _RemoteSigner implements Signer {
  _RemoteSigner(this._worker, this._profile, this.publicKey);
  final ChainWorker _worker;
  final String _profile;

  @override
  final String publicKey;

  @override
  Future<Uint8List> sign(Uint8List message) {
    final id = _worker._nextSign++;
    final c = Completer<Uint8List>();
    _worker._signing[id] = c;
    _worker._out(['sign', id, _profile, message]);
    return c.future;
  }
}

/// A profile that follows the chain lightly (phones): headers and proven
/// reads, no blocks to check, nothing kept.
class _LightMember {
  _LightMember(this.profileId, this.signer, this.address, this.rendezvous, this.spec, this.light);

  final String profileId;
  final Signer signer;
  final String address;

  /// The network's meeting point (TestnetSpec.rendezvousSeeds).
  final String rendezvous;
  final TestnetSpec spec;
  final LightClient light;

  int balance = 0;
  int nonce = 0;
  int standing = 0;
  int syncScore = 0;
  CircleState? circle;
  final pending = <Tx>[];
  String readAt = '';
  int readTick = 0;
  bool reading = false;
  String lastState = '';
  Timer? timer;
  int ticks = 0;

  String get pubkey => signer.publicKey;

  /// The private wallet (wallet.dart).
  late Wallet wallet;
}

class _Member {
  _Member(this.profileId, this.signer, this.address, this.arcaAddress, this.dir, this.spec, this.node);

  final String profileId;
  final Signer signer;
  final String address;
  final String arcaAddress;
  final String dir;
  final TestnetSpec spec;
  final ChainNode node;

  /// The logs of the circles this member runs (as admin), by circle.
  final logs = <String, CircleLog>{};

  /// The circle this member keeps files for.
  late String keepCircle = spec.circleId;

  /// The network's meeting point, which this member answers for too
  /// (TestnetSpec.rendezvousSeeds).
  String rendezvous = '';

  /// This member's chain's headers, served to newcomers that check it.
  late HeaderArchive archive;
  Map<String, String> files = {};
  Corpus? corpus;
  String? corpusError;
  bool buildingCorpus = false;
  Set<int> keep = {};
  final packing = <int, double>{};

  /// The user's choice: take part in making blocks.
  bool miningWanted = true;
  final packed = <int>{};
  String lastState = '';
  Timer? timer;
  int ticks = 0;

  String get pubkey => node.key;

  /// The private wallet (wallet.dart).
  late Wallet wallet;
}

class ChainWorker {
  ChainWorker(this._out) : _link = _ProxyLink(_out);

  final void Function(List<Object?>) _out;
  final _ProxyLink _link;
  final _members = <String, _Member>{};
  final _lights = <String, _LightMember>{};
  final _parts = Reassembly();
  final _waiting = <String, Completer<Map>>{};
  final _signing = <int, Completer<Uint8List>>{};

  /// The device's power and connection, from the UI (plugins run there).
  bool _charging = true;
  bool _unmetered = true;

  /// The device's sharing limits (Settings): heavy work waits for them.
  bool _onlyCharging = false;
  bool _onlyUnmetered = false;

  /// Whether now is inside the owner's sharing hours.
  bool _inHours = true;

  /// Why heavy work waits for [m], or null when it may run. Daily proofs
  /// are not held back: a missed one loses everything.
  String? _paused(_Member m) {
    if (_onlyCharging && !_charging) return 'charging';
    if (_onlyUnmetered && !_unmetered) return 'network';
    if (!_inHours) return 'hours';
    return null;
  }

  void _applyPower(_Member m) => m.node.mining = m.miningWanted && _paused(m) == null;
  var _nextId = 0;
  var _nextSign = 0;

  void receive(List m) {
    switch (m[0]) {
      case 'in':
        final bytes = m[3] as Uint8List;
        final inbound = Inbound(m[1] as String, m[2] as String, bytes);
        _link._in.add(inbound);
        // Answers to this worker's own requests (log, checkpoint, peers),
        // and the meeting point's traffic.
        final msg = _parts.add(inbound);
        if (msg == null) break;
        _onMeeting(inbound, msg);
        if (msg['id'] != null && const {'log', 'checkpoint', 'snapshot', 'headers', 'proof', 'outputs'}.contains(msg['t'])) {
          _waiting.remove('${msg['id']}')?.complete(msg);
        }
      case 'signed':
        _signing.remove(m[1])?.complete(m[2] as Uint8List);
      case 'cmd':
        final id = m[1];
        unawaited(
          _command(m[2] as String, (m[3] as Map).cast<String, Object?>())
              .then((r) => _out(['reply', id, r]))
              .catchError(
                (Object e) => _out([
                  'reply',
                  id,
                  {'error': '$e'},
                ]),
              ),
        );
    }
  }

  // ---- Finding peers ----

  /// Full nodes this member knows (light ones ask, they do not serve).
  static Iterable<String> _fullPeers(_Member m) => m.node.peers.where((p) => !m.node.lightPeers.contains(p));

  void _sendMsg(String from, String to, Map<String, Object?> msg) {
    for (final part in Reassembly.split(msg)) {
      _out(['send', to, encodeChainMessage(part), from]);
    }
  }

  final _meetings = <String, void Function(List<String>)>{};

  /// Says hello at the meeting point and gathers every answer: after the
  /// first, it listens a while longer, since every node answering there
  /// gets the hello and one honest answer is enough (the heaviest chain
  /// that holds up is followed, however many nodes vouch for others).
  Future<List<String>> _meet(String from, String rendezvous, {required bool full, required ChainParams params}) async {
    final id = 'w${_nextId++}';
    final found = <String>{};
    final first = Completer<void>();
    _meetings[id] = (peers) {
      found.addAll(peers);
      if (!first.isCompleted) first.complete();
    };
    void send() => _sendMsg(from, rendezvous, {'t': 'hello', 'full': full, 'id': id});
    send();
    final again = Timer.periodic(const Duration(seconds: 10), (_) => send());
    try {
      // A meeting point whose lease set was just published can take a few
      // minutes to be found.
      await first.future.timeout(const Duration(minutes: 4));
      // Two blocks' time: 20 s on the test network.
      await Future<void>.delayed(Duration(milliseconds: (params.blockTicks * params.tickMillis * 2).clamp(500, 20000)));
    } on TimeoutException {
      throw TimeoutException('No node of the test network answered. Try again in a minute.');
    } finally {
      again.cancel();
      _meetings.remove(id);
    }
    return (found..remove(from)).toList();
  }

  /// Where this device's check of a chain starts: a checkpoint built into
  /// this release, or genesis.
  static Anchor _anchorFor(TestnetSpec spec) => TestnetSpec.builtInCheckpoint ?? Anchor.genesis(spec.genesisTick);

  /// Checks the chains of [peers] (chain/verify.dart) and returns the
  /// heaviest that holds up, with the headers fetched along the way.
  Future<({String peer, List<Header> chain, Map<String, Header> full, BigInt work})> _choose(
    TestnetSpec spec,
    String from,
    List<String> peers,
    Anchor anchor,
  ) async {
    final checker = ChainChecker(params: spec.params, corpusRoot: spec.corpusRoot, partitionSizes: spec.partitionSizes);
    ({String peer, List<Header> chain, Map<String, Header> full, BigInt work})? best;
    final why = <String>[];
    // Each peer's chain at once: a peer that is gone costs one wait, not
    // one each.
    Future<void> tryPeer(String peer) async {
      try {
        const page = 40;
        final chain = <Header>[];
        for (var at = anchor.height + 1; ; at += page) {
          final r = await _ask(from, peer, {'t': 'getHeaders', 'from': at, 'n': page}, wait: const Duration(seconds: 45));
          final hs = [for (final h in r['headers'] as List) Header.fromJson(h as Map)];
          if (hs.isNotEmpty && hs.first.height != at) throw StateError('it cannot show its chain from our anchor');
          chain.addAll(hs);
          if (hs.length < page) break;
        }
        final full = <String, Header>{};
        Future<Header?> fetch(Header s) async {
          for (final p in [peer, ...peers.where((x) => x != peer)].take(3)) {
            try {
              final r = await _ask(from, p, {'t': 'getProof', 'hash': s.hash}, wait: const Duration(seconds: 45));
              if (r['header'] case final Map h) return full[s.hash] = Header.fromJson(h);
            } on Object {
              // Ask the next.
            }
          }
          return null;
        }

        final r = await checker.check(anchor, chain, fetch);
        if (!r.ok) {
          why.add(r.error!);
          return;
        }
        final b = best;
        if (b == null || r.work! > b.work) best = (peer: peer, chain: chain, full: full, work: r.work!);
      } on Object catch (e) {
        why.add('$e');
      }
    }

    await Future.wait([for (final p in peers.take(6)) tryPeer(p)]);
    final chosen = best;
    if (chosen == null) {
      throw StateError('No chain shown by the nodes met holds up (${why.take(3).join('; ')}).');
    }
    return chosen;
  }

  /// A hello to the meeting point: whichever full node gets it answers
  /// with its own address and the full nodes it knows.
  void _hello(String from, String rendezvous, {required bool full}) =>
      _sendMsg(from, rendezvous, {'t': 'hello', 'full': full});

  void _onMeeting(Inbound m, Map msg) {
    switch (msg['t']) {
      case 'hello':
        final member = _members.values.where((x) => x.rendezvous == m.to && x.address != m.from).firstOrNull;
        if (member == null) return;
        if (msg['full'] == true) member.node.peers.add(m.from);
        _sendMsg(member.address, m.from, {
          't': 'peers',
          'peers': [member.address, ..._fullPeers(member).where((p) => p != m.from).take(15)],
          if (msg['id'] != null) 'id': msg['id'],
        });
      case 'peers':
        final found = [for (final p in msg['peers'] as List? ?? const []) '$p'];
        if (msg['id'] != null) _meetings['${msg['id']}']?.call(found);
        for (final x in _members.values.where((x) => x.address == m.to)) {
          x.node.peers.addAll(found.where((p) => p != x.address));
        }
        for (final x in _lights.values.where((x) => x.address == m.to)) {
          x.light.peers.addAll(found.where((p) => p != x.address));
        }
    }
  }

  // ---- The private wallet ----

  /// The wallet of the profile joining with [a]: its scan key and spend
  /// point come from the core, which keeps the spend key.
  Future<Wallet> _wallet(Map<String, Object?> a, String dir) async {
    final scan = BigInt.parse(a['scanKey'] as String, radix: 16);
    final spend = Point.decode(fromHex(a['spend'] as String))!;
    final w = Wallet(ViewKeys(scan, spend), WalletAddress(Point.g * scan, spend), File('$dir/wallet.json'));
    await w.load();
    return w;
  }

  /// Signs an input of [profile]'s wallet: the core adds the spend key to t.
  InputSigner _inputSigner(String profile) => (input, message) {
    final id = _nextSign++;
    final c = Completer<Uint8List>();
    _signing[id] = c;
    _out(['signPoint', id, profile, input.t.toRadixString(16), Uint8List.fromList(message)]);
    return c.future;
  };

  /// Pays [amount] grains to the wallet address [to] from [w]: coins, change
  /// back to itself, and a transaction that names no account.
  Future<({Tx? tx, String? error})> _pay(Wallet w, String profile, String to, int amount) async {
    final address = WalletAddress.parse(to);
    if (address == null) return (tx: null, error: 'That is not a wallet address (marca1...).');
    if (amount <= 0) return (tx: null, error: 'Enter an amount above zero.');
    final coins = w.pick(BigInt.from(amount));
    if (coins == null) return (tx: null, error: 'The private balance is not enough for that.');
    final change = coins.fold(BigInt.zero, (n, o) => n + o.value) - BigInt.from(amount);
    final built = await buildPrivate(
      signInput: _inputSigner(profile),
      inputs: coins,
      payments: [(address, BigInt.from(amount)), if (change > BigInt.zero) (w.address, change)],
    );
    w.markSpending(coins.map((c) => c.commitment));
    return (tx: Tx(type: TxType.private, from: '', nonce: 0, body: built.body, sig: ''), error: null);
  }

  /// The body moving [amount] grains between [w]'s public balance and its
  /// private side: in (+) or out (-). Null with an error when it cannot.
  Future<({Future<Map<String, Object?>> Function(String from, int nonce)? build, String? error})> _move(
    Wallet w,
    String profile,
    int amount,
    int publicBalance,
  ) async {
    if (amount == 0) return (build: null, error: 'Enter an amount above zero.');
    if (amount > 0 && publicBalance < amount) return (build: null, error: 'The public balance is not enough for that.');
    List<Owned> coins = const [];
    var change = BigInt.zero;
    if (amount < 0) {
      final picked = w.pick(BigInt.from(-amount));
      if (picked == null) return (build: null, error: 'The private balance is not enough for that.');
      coins = picked;
      change = coins.fold(BigInt.zero, (n, o) => n + o.value) + BigInt.from(amount);
      w.markSpending(coins.map((c) => c.commitment));
    }
    final payments = [
      if (amount > 0) (w.address, BigInt.from(amount)),
      if (change > BigInt.zero) (w.address, change),
    ];
    return (
      build: (String from, int nonce) async => (await buildPrivate(
        signInput: _inputSigner(profile),
        inputs: coins,
        payments: payments,
        pub: amount,
        from: from,
        nonce: nonce,
      )).body,
      error: null,
    );
  }

  Future<Map<String, Object?>> _command(String name, Map<String, Object?> a) async {
    final light = _lights[a['profile']];
    if (light != null && name != 'join') return _lightCommand(light, name, a);
    switch (name) {
      case 'build':
        // A founder's spec from their collection's files.
        final params = a['params'] == null ? ChainParams.testnet : ChainParams.fromJson(a['params'] as Map);
        final paths = (a['paths'] as List).cast<String>();
        final (files, corpus, bySha) = await _offCorpusOfPaths(params, paths);
        final spec = TestnetSpec.create(
          names: {for (final e in bySha.entries) e.key: e.value.split('/').last},
          founder: a['founder'] as String,
          collectionOwner: a['founder'] as String,
          collectionId: a['collection'] as String,
          collectionName: a['name'] as String,
          files: files,
          corpusRoot: corpus.rootHex,
          partitionSizes: [for (var i = 0; i < corpus.partitions; i++) corpus.chunksIn(i)],
          params: params,
        );
        return {'spec': spec.json};
      case 'checkpoint':
        // The head as a checkpoint for a release (tool/seed_node.dart).
        final m = _members[a['profile']];
        return m == null ? {'error': 'This profile keeps no files here.'} : {'anchor': m.node.headAnchor.toJson()};
      case 'peers':
        // The full nodes a member found: where its copy of the corpus comes
        // from.
        final m = _members[a['profile']];
        return {'peers': m == null ? const <String>[] : _fullPeers(m).toList()};
      case 'join':
        await _join(a);
        return {};
      case 'files':
        final m = _members[a['profile']];
        if (m != null) {
          m.files = (a['files'] as Map).cast<String, String>();
          unawaited(_prepare(m));
        }
        return {};
      case 'keep':
        final m = _members[a['profile']]!;
        final p = a['partition'] as int;
        if (a['keep'] == true) {
          m.keep.add(p);
        } else {
          m.keep.remove(p);
          if (m.node.state.declarations[m.pubkey]?.containsKey(p) ?? false) {
            m.node.submit(TxType.undeclare, {
              'partitions': [p],
            });
          }
        }
        unawaited(_prepare(m));
        return {'keep': m.keep.toList()..sort()};
      case 'mining':
        final m = _members[a['profile']]!;
        m.miningWanted = a['on'] as bool? ?? m.miningWanted;
        _applyPower(m);
        unawaited(_prepare(m));
        return {};
      case 'power':
        _charging = a['charging'] as bool? ?? true;
        _unmetered = a['unmetered'] as bool? ?? true;
        _onlyCharging = a['onlyCharging'] as bool? ?? false;
        _onlyUnmetered = a['onlyUnmetered'] as bool? ?? false;
        _inHours = a['inHours'] as bool? ?? true;
        for (final m in _members.values) {
          _applyPower(m);
          unawaited(_prepare(m));
        }
        return {};
      case 'send':
        final m = _members[a['profile']]!;
        final r = await _pay(m.wallet, m.profileId, a['to'] as String? ?? '', a['amount'] as int);
        if (r.error != null) return {'error': r.error};
        m.node.submitTx(r.tx!);
        return {};
      case 'move':
        // Between the public balance and the private side.
        final m = _members[a['profile']]!;
        final r = await _move(m.wallet, m.profileId, a['amount'] as int, m.node.state.balanceOf(m.pubkey));
        if (r.error != null) return {'error': r.error};
        await m.node.submitBuilt(TxType.private, (nonce) => r.build!(m.pubkey, nonce));
        return {};
      case 'payout':
        final m = _members[a['profile']]!;
        return _payout(m, a['circle'] as String? ?? m.keepCircle);
      case 'reading':
        // The admin's reading settings, into the circle's log and, with the
        // next anchor, onto the chain.
        final m = _members[a['profile']]!;
        final circleId = a['circle'] as String? ?? m.keepCircle;
        final log = m.logs[circleId];
        if (log == null || log.admin != m.pubkey) return {'error': 'Only the circle\'s admin sets how it is read.'};
        final policy = {...log.policy.toJson(), ...(a['reading'] as Map).cast<String, Object?>()};
        try {
          await log.writeWith(m.signer, LogType.policy, policy);
        } on LogError catch (e) {
          return {'error': e.message};
        }
        await _saveLog(m, circleId);
        return {};
      case 'buyPass':
        final m = _members[a['profile']]!;
        final circleId = a['circle'] as String? ?? m.keepCircle;
        final circle = m.node.state.circles[circleId];
        if (circle == null || circle.passPrice <= 0) return {'error': 'This circle sells no passes.'};
        if (m.node.state.balanceOf(m.pubkey) < circle.passPrice) {
          return {'error': 'The balance is not enough for a pass.'};
        }
        final tx = await m.node.submit(TxType.buyPass, {'circle': circleId});
        return {'pass': tx.id};
      case 'createCircle':
        return _createCircle(_members[a['profile']]!, a['circle'] as String? ?? '', a['name'] as String? ?? '');
      case 'keepFor':
        final m = _members[a['profile']]!;
        final circleId = a['circle'] as String? ?? '';
        if (!m.node.state.circles.containsKey(circleId)) return {'error': 'No such circle on the chain.'};
        m.keepCircle = circleId;
        // Declaring again for another circle moves the keeping (and what it
        // earns) there.
        final declared = m.node.state.declarations[m.pubkey]?.keys.toList() ?? const <int>[];
        if (declared.isNotEmpty) {
          await m.node.submit(TxType.declare, {'circle': circleId, 'partitions': declared..sort()});
        }
        return {};
      case 'settle':
        // Receipts this profile's server kept, for passes that ended.
        final m = _members[a['profile']]!;
        final s = m.node.state;
        var sent = 0;
        for (final e in (a['receipts'] as Map).entries) {
          final pass = s.passes[e.key];
          final r = (e.value as Map).cast<String, Object?>();
          if (pass == null || pass.activeAt(s.tick) || pass.delivered.containsKey(m.pubkey)) continue;
          final waiting = m.node.waiting.any((t) => t.type == TxType.settlePass && t.body['pass'] == e.key);
          if (waiting) continue;
          await m.node.submit(TxType.settlePass, {'pass': e.key, 'bytes': r['bytes'], 'sig': r['sig']});
          sent++;
        }
        return {'settled': sent};
      case 'claim':
        final m = _members[a['profile']]!;
        return _claim(m, a['circle'] as String? ?? m.keepCircle);
      case 'leave':
        final m = _members.remove(a['profile']);
        if (m != null) await _close(m);
        _out(['state', a['profile'], null]);
        return {};
    }
    return {'error': 'unknown chain command $name'};
  }

  /// Sends [msg] from [from] to [to] and waits for the answer, sending it
  /// again every 10 seconds: the first messages over a new I2P tunnel are
  /// often lost.
  Future<Map> _ask(String from, String to, Map<String, Object?> msg, {Duration wait = const Duration(seconds: 90)}) async {
    final id = 'w${_nextId++}';
    final c = Completer<Map>();
    _waiting[id] = c;
    void send() {
      for (final part in Reassembly.split({...msg, 'id': id})) {
        _out(['send', to, encodeChainMessage(part), from]);
      }
    }

    send();
    final again = Timer.periodic(const Duration(seconds: 10), (_) => send());
    try {
      return await c.future.timeout(wait);
    } on TimeoutException {
      throw TimeoutException('No answer over I2P. Is the other device online?');
    } finally {
      again.cancel();
      _waiting.remove(id);
    }
  }

  Future<void> _join(Map<String, Object?> a) async {
    final profile = a['profile'] as String;
    if (_members.containsKey(profile) || _lights.containsKey(profile)) return;
    if (a['light'] == true) return _joinLight(a);
    final spec = TestnetSpec((a['spec'] as Map).cast<String, Object?>());
    final dir = a['dir'] as String;
    await Directory(dir).create(recursive: true);
    // The key stays in the core; signatures are asked of it.
    final signer = _RemoteSigner(this, profile, a['pubkey'] as String);
    final address = a['address'] as String;
    final genesis = spec.genesis();
    // The peers heard from before a restart are told of our new blocks at
    // once; otherwise a founder, which starts with no peers, would wait to
    // be reached, and those who cached its old tunnels could not reach it
    // until their cache ran out (docs/performance.md, 3.16).
    final peers = {...(a['peers'] as List).cast<String>(), ...await _loadPeers(dir)}.toList();
    final snap = File('$dir/snapshot.json');
    ChainNode? node;
    if (await snap.exists()) {
      try {
        node = ChainNode.fromSnapshot(
          jsonDecode(await snap.readAsString()) as Map,
          params: spec.params,
          genesisRoot: genesis.rootHex,
          address: address,
          link: _link,
          signer: signer,
          peers: peers,
        );
      } catch (_) {
        // A snapshot this version cannot read (its format changed): set it
        // aside and catch up from genesis and the peers instead.
        await snap.rename('${snap.path}.unreadable');
      }
    }
    // A newcomer starts from a full node's recent state, not from genesis:
    // nodes keep no blocks older than their own snapshot. It meets them at
    // the network's meeting point, checks the chain each of them shows from
    // an anchor it trusts (chain/verify.dart), and takes the state at the
    // tip of the heaviest that holds up, checked against that tip. Only the
    // founder starts from genesis.
    final rendezvous = a['rendezvous'] as String;
    final archive = HeaderArchive(File('$dir/headers.json'), _anchorFor(spec));
    await archive.load();
    if (node == null && spec.founder != a['pubkey']) {
      final met = await _meet(address, rendezvous, full: true, params: spec.params);
      peers.addAll(met.where((p) => !peers.contains(p)));
      final anchor = _anchorFor(spec);
      final best = await _choose(spec, address, met, anchor);
      archive
        ..anchor = anchor
        ..put([for (final h in best.chain) best.full[h.hash] ?? h]);
      if (best.chain.isNotEmpty) {
        final tip = best.full[best.chain.last.hash];
        if (tip == null) throw StateError('The chain\'s newest header came without its proof.');
        // The state at that tip, from the node that showed the chain or
        // another that holds it; checked against the tip's state root.
        Map<String, Object?>? boot;
        Object? failed;
        for (final p in [best.peer, ...met.where((x) => x != best.peer)]) {
          try {
            boot = await _bootstrap(spec, address, p, at: tip, work: best.work);
            break;
          } on Object catch (e) {
            failed = e;
          }
        }
        if (boot == null) throw failed ?? StateError('No node sent the state at the chain\'s tip.');
        node = ChainNode.fromSnapshot(
          boot,
          params: spec.params,
          genesisRoot: genesis.rootHex,
          address: address,
          link: _link,
          signer: signer,
          peers: peers,
        );
      }
    }
    node ??= ChainNode(
      params: spec.params,
      genesis: genesis,
      address: address,
      link: _link,
      signer: signer,
      peers: peers,
    );
    final m = _Member(profile, signer, address, a['arcaAddress'] as String, dir, spec, node)
      ..wallet = await _wallet(a, dir)
      ..keep = {...(a['keep'] as List? ?? const []).cast<int>()}
      ..files = (a['files'] as Map? ?? const {}).cast<String, String>()
      ..rendezvous = rendezvous
      ..archive = archive;
    m.miningWanted = a['mining'] as bool? ?? true;
    _applyPower(m);
    m.keepCircle = a['keepCircle'] as String? ?? spec.circleId;
    // The logs of the circles this member runs: the founder's genesis circle
    // in log.json, circles it created in log-<circle>.json.
    await for (final f in Directory(dir).list()) {
      final name = f.path.split('/').last;
      final match = RegExp(r'^log(?:-([a-z0-9-]+))?\.json$').firstMatch(name);
      if (f is! File || match == null) continue;
      final circleId = match.group(1) ?? spec.circleId;
      final entries = [for (final e in jsonDecode(await f.readAsString()) as List) LogEntry.fromJson(e as Map)];
      if (entries.isEmpty) continue;
      m.logs[circleId] = CircleLog.replay(circleId, entries.first.author, entries);
    }
    if (!m.logs.containsKey(spec.circleId) && spec.founder == node.key) {
      // The admin appoints itself moderator: moderators accept collections.
      final log = CircleLog(spec.circleId, admin: spec.founder);
      await log.writeWith(signer, LogType.appoint, {'key': spec.founder});
      await log.writeWith(signer, LogType.collection, {
        'id': 'corpus',
        'partitions': [for (var i = 0; i < spec.partitionSizes.length; i++) i],
        'root': spec.corpusRoot,
      });
      m.logs[spec.circleId] = log;
      await _saveLog(m, spec.circleId);
    }
    Future<Map<String, Object?>?> answer(String from, Map msg) async {
      switch (msg['t']) {
        case 'getOutputs':
          // Unspent outputs, for light wallets to scan (they keep only what
          // a proven read confirms).
          final raw = m.node.state.outputs.raw;
          final keys = raw.keys.toList()..sort();
          final from = msg['from'] as int? ?? 0;
          return {
            't': 'outputs',
            'outputs': {for (final k in keys.skip(from).take(100)) k: raw[k]},
            'next': from + 100 < keys.length ? from + 100 : null,
          };
        case 'getHeaders':
          final n = (msg['n'] as int? ?? 40).clamp(1, 40);
          return {
            't': 'headers',
            'headers': [for (final h in m.archive.summaries(msg['from'] as int? ?? 1, n)) h.toJson()],
          };
        case 'getProof':
          final h = m.archive.byHash('${msg['hash']}');
          return {'t': 'proof', 'header': h == null || h.isSummary ? null : h.toJson()};
        case 'getLog' when m.logs.containsKey(msg['circle'] ?? spec.circleId):
          return {
            't': 'log',
            'entries': [for (final e in m.logs[msg['circle'] ?? spec.circleId]!.entries) e.toJson()],
          };
      }
      return null;
    }

    node.answer = answer;
    // Each anchor also says where the log can be fetched: here.
    node.anchorBody = (circle) => m.logs[circle] == null ? null : {...m.logs[circle]!.anchorBody(), 'logAt': address};
    _members[profile] = m;
    node.start();
    m.timer = Timer.periodic(const Duration(seconds: 1), (_) => _tick(m));
    unawaited(_prepare(m));
  }

  // ---- Light mode ----

  /// A light device checks the chain it is shown (chain/verify.dart) from
  /// an anchor it trusts: the last tip it checked (kept in light.json), a
  /// checkpoint built into the release, or genesis. It then follows from
  /// that chain's tip and never takes a checkpoint on trust.
  Future<void> _joinLight(Map<String, Object?> a) async {
    final profile = a['profile'] as String;
    final spec = TestnetSpec((a['spec'] as Map).cast<String, Object?>());
    final address = a['address'] as String, rendezvous = a['rendezvous'] as String;
    final dir = a['dir'] as String;
    await Directory(dir).create(recursive: true);
    final saved = File('$dir/light.json');
    var anchor = _anchorFor(spec);
    Header? start;
    BigInt? work;
    try {
      final j = jsonDecode(await saved.readAsString()) as Map;
      start = Header.fromJson(j['header'] as Map);
      work = BigInt.parse(j['work'] as String);
      anchor = Anchor(hash: start.hash, height: start.height, tick: start.tick, work: work);
    } on Object {
      // Nothing checked yet on this device.
    }
    final met = await _meet(address, rendezvous, full: false, params: spec.params);
    final best = await _choose(spec, address, met, anchor);
    if (best.chain.isNotEmpty) {
      start = best.full[best.chain.last.hash];
      if (start == null) throw StateError('The chain\'s newest header came without its proof.');
      work = best.work;
      await saved.writeAsString(jsonEncode({'header': start.toJson(), 'work': '$work'}));
    }
    final light = LightClient(
      params: spec.params,
      genesisRoot: spec.genesis().rootHex,
      genesisTick: spec.genesisTick,
      address: address,
      link: _link,
      peers: met,
      askCheckpoint: false,
    );
    if (start != null) light.trust(start, work!);
    final m = _LightMember(profile, _RemoteSigner(this, profile, a['pubkey'] as String), address, rendezvous, spec, light)
      ..wallet = await _wallet(a, dir);
    _lights[profile] = m;
    light.start();
    m.timer = Timer.periodic(const Duration(seconds: 1), (_) => _lightTick(m));
  }

  Future<void> _lightTick(_LightMember m) async {
    m.ticks++;
    if (m.ticks % (m.light.peers.isEmpty ? 15 : 300) == 1) _hello(m.address, m.rendezvous, full: false);
    // Waiting transactions again every ten seconds: a full node may not
    // have heard them.
    if (m.ticks % 10 == 0) {
      for (final t in m.pending) {
        m.light.broadcast({'t': 'tx', 'tx': t.toJson()});
      }
    }
    // A light device reads its balance and standing with proofs, five
    // requests over I2P: at each new block while a transaction of its own
    // waits, otherwise every six blocks (a minute on the test network),
    // which is what the wallet shows (docs/performance.md, 3.18).
    final head = m.light.headHash;
    final p = m.spec.params;
    final every = (p.blockTicks * p.tickMillis * _lightReadBlocks / 1000).ceil();
    final due = m.readAt.isEmpty || m.pending.isNotEmpty || m.ticks - m.readTick >= every;
    if (!m.reading && head.isNotEmpty && head != m.readAt && due) {
      m.reading = true;
      try {
        await _lightRead(m, head);
        await _lightWallet(m, head);
        m.readAt = head;
        m.readTick = m.ticks;
      } catch (_) {
        // A full node that did not answer: next time.
      } finally {
        m.reading = false;
      }
    }
    final s = _lightState(m);
    final text = jsonEncode(s);
    if (text != m.lastState) {
      m.lastState = text;
      _out(['state', m.profileId, s]);
    }
  }

  /// Blocks between a light device's reads when nothing of its own waits.
  static const _lightReadBlocks = 6;

  /// A light wallet scans the unspent outputs a full node lists, and keeps
  /// only those a proven read at [at] confirms: a node can hide an output
  /// from it, not invent one.
  Future<void> _lightWallet(_LightMember m, String at) async {
    final peer = m.light.peers.firstOrNull;
    if (peer == null) return;
    final all = <String, String>{};
    int? next = 0;
    while (next != null) {
      final r = await _ask(m.address, peer, {'t': 'getOutputs', 'from': next}, wait: const Duration(seconds: 45));
      all.addAll((r['outputs'] as Map).cast<String, String>());
      next = r['next'] as int?;
    }
    m.wallet.update(all);
    if (m.wallet.owned.isNotEmpty) {
      final proven = await m.light.read('outputs', m.wallet.owned.keys.toList(), at: at);
      m.wallet.owned.removeWhere((k, _) => proven[k]?.value == null);
    }
    await m.wallet.save();
  }

  Future<void> _lightRead(_LightMember m, String at) async {
    final me = m.pubkey;
    final balances = await m.light.read('balances', [me], at: at);
    final nonces = await m.light.read('nonces', [me], at: at);
    final circles = await m.light.read('circles', [m.spec.circleId], at: at);
    final standing = await m.light.read('standing', [me], at: at);
    final sync = await m.light.read('sync', ['${m.spec.circleId} $me'], at: at);
    m.balance = int.tryParse(balances[me]?.value ?? '') ?? 0;
    m.nonce = int.tryParse(nonces[me]?.value ?? '') ?? 0;
    final c = circles[m.spec.circleId]?.value;
    m.circle = c == null ? null : CircleState.fromJson(jsonDecode(c) as Map);
    final st = standing[me]?.value;
    m.standing = st == null ? 0 : (jsonDecode(st) as List)[1] as int;
    final sc = sync['${m.spec.circleId} $me']?.value;
    m.syncScore = sc == null ? 0 : (jsonDecode(sc) as List)[1] as int;
    m.pending.removeWhere((t) => TxType.numbered(t.type) && t.nonce < m.nonce);
  }

  Map<String, Object?> _lightState(_LightMember m) {
    final params = m.spec.params;
    final h = m.light.header(m.light.headHash);
    final tick = h?.tick ?? m.spec.genesisTick;
    final day = tick < m.spec.genesisTick ? 0 : (tick - m.spec.genesisTick) ~/ params.dayTicks;
    final c = m.circle;
    return {
      'light': true,
      'spec': m.spec.hash,
      'name': m.spec.corpusName,
      'founder': false,
      'height': m.light.height,
      'day': day,
      'nextDayAt': (m.spec.genesisTick + (day + 1) * params.dayTicks) * params.tickMillis,
      'dayLength': params.dayTicks * params.tickMillis ~/ 1000,
      'behind':
          h == null || DateTime.now().millisecondsSinceEpoch ~/ params.tickMillis - h.tick > params.blockTicks * 10,
      'peers': m.light.peers.length,
      'balance': m.balance,
      'private': m.wallet.balance.toInt(),
      'address': m.wallet.address.encoded,
      'pending': m.pending.length,
      'mining': false,
      'paused': null,
      'standing': m.standing,
      'syncScore': m.syncScore,
      'corpus': {'ready': false, 'building': false, 'error': null, 'files': m.spec.files.length, 'present': 0},
      'partitions': const [],
      if (c != null) ...{
        'circle': {
          'id': m.spec.circleId,
          'name': c.name,
          'pool': c.pool,
          'admin': c.admin == m.pubkey,
          'claimed': c.claimed[m.pubkey] ?? 0,
          'payoutRoot': c.payoutRoot,
        },
        'reading': {
          'passPrice': c.passPrice,
          'freeAllowance': c.freeAllowance > 0 ? c.freeAllowance : 1 << 30,
          'memberScore': c.memberScore,
          'members': const [],
          'passes': const {},
          'ended': const [],
        },
      },
    };
  }

  /// Signs [type] as [m] with the next nonce and hands it to full nodes.
  Future<Tx> _lightSubmit(_LightMember m, String type, Map<String, Object?> body) async {
    final nonce = TxType.numbered(type) ? m.nonce + m.pending.where((t) => TxType.numbered(t.type)).length : 0;
    final tx = await Tx.signWith(m.signer, type, nonce, body);
    m.pending.add(tx);
    m.light.broadcast({'t': 'tx', 'tx': tx.toJson()});
    return tx;
  }

  Future<Map<String, Object?>> _lightCommand(_LightMember m, String name, Map<String, Object?> a) async {
    switch (name) {
      case 'send':
        final r = await _pay(m.wallet, m.profileId, a['to'] as String? ?? '', a['amount'] as int);
        if (r.error != null) return {'error': r.error};
        m.light.broadcast({'t': 'tx', 'tx': r.tx!.toJson()});
        return {};
      case 'move':
        final r = await _move(m.wallet, m.profileId, a['amount'] as int, m.balance);
        if (r.error != null) return {'error': r.error};
        final nonce = m.nonce + m.pending.where((t) => TxType.numbered(t.type)).length;
        final tx = await Tx.signWith(m.signer, TxType.private, nonce, await r.build!(m.pubkey, nonce));
        m.pending.add(tx);
        m.light.broadcast({'t': 'tx', 'tx': tx.toJson()});
        return {};
      case 'buyPass':
        final c = m.circle;
        if (c == null || c.passPrice <= 0) return {'error': 'This circle sells no passes.'};
        if (m.balance < c.passPrice) return {'error': 'The balance is not enough for a pass.'};
        final tx = await _lightSubmit(m, TxType.buyPass, {'circle': m.spec.circleId});
        return {'pass': tx.id};
      case 'claim':
        final c = m.circle;
        if (c == null) return {'error': 'The circle is not read yet; try again in a moment.'};
        final r = await _claimBody(m.spec, m.spec.circleId, c, m.pubkey, null, m.address, m.light.peers.firstOrNull);
        if (r['body'] case final Map body) {
          await _lightSubmit(m, TxType.claim, body.cast<String, Object?>());
          return {'claimed': r['owed']};
        }
        return r;
      case 'leave':
        _lights.remove(m.profileId);
        m.timer?.cancel();
        await m.light.stop();
        _out(['state', m.profileId, null]);
        return {};
      case 'power' || 'mining' || 'files' || 'settle':
        return {};
    }
    return {'error': 'Keeping files and running the circle need the full mode on this device.'};
  }

  /// A full node's head header (a checkpoint, trusted on first use) and the
  /// state after it, every namespace checked against
  /// the header's state root. Null when the chain has no block yet.
  Future<Map<String, Object?>?> _bootstrap(TestnetSpec spec, String from, String to, {Header? at, BigInt? work}) async {
    // At a header the chain check vouched for, or else the peer's head.
    final Map cp;
    if (at != null) {
      cp = {'header': at.toJson(), 'work': '$work'};
    } else {
      cp = await _ask(from, to, {'t': 'getCheckpoint'});
    }
    if (cp['header'] == null) return null;
    final header = Header.fromJson(cp['header'] as Map);
    if (!header.signed) throw StateError('The checkpoint a peer sent is not signed.');
    final entries = <String, Map<String, String>>{};
    List<String>? roots;
    for (final ns in ChainState.namespaces) {
      final got = <String, String>{};
      int? next = 0;
      while (next != null) {
        final page = await _ask(from, to, {'t': 'snapshot', 'at': header.hash, 'ns': ns, 'from': next});
        roots ??= [for (final r in page['roots'] as List) r as String];
        got.addAll((page['entries'] as Map).cast<String, String>());
        next = page['next'] as int?;
      }
      entries[ns] = got;
    }
    if (toHex(ChainState.stateRootOf([for (final r in roots!) fromHex(r)])) != header.stateRoot) {
      throw StateError('A peer\'s state is not the one its checkpoint names.');
    }
    for (var i = 0; i < ChainState.namespaces.length; i++) {
      if (toHex(smtRoot(entries[ChainState.namespaces[i]]!)) != roots[i]) {
        throw StateError('A peer\'s ${ChainState.namespaces[i]} do not match their root.');
      }
    }
    return {'block': header.asBlock.toJson(), 'work': cp['work'], 'state': entries};
  }

  Future<void> _saveLog(_Member m, String circle) async {
    final f = File(circle == m.spec.circleId ? '${m.dir}/log.json' : '${m.dir}/log-$circle.json');
    await File('${f.path}.tmp').writeAsString(jsonEncode([for (final e in m.logs[circle]!.entries) e.toJson()]));
    await File('${f.path}.tmp').rename(f.path);
  }

  void _archive(_Member m) {
    final from = max(m.archive.anchor.height + 1, m.archive.height - 20);
    m.archive.put([for (final b in m.node.chainFrom(from)) Header.of(b)]);
  }

  Future<void> _saveSnapshot(_Member m) async {
    // The archive reaches the snapshot's block, so the node serves the
    // state at its archive's tip after a restart.
    _archive(m);
    await m.archive.save();
    final f = File('${m.dir}/snapshot.json');
    await File('${f.path}.tmp').writeAsString(jsonEncode(m.node.snapshot()));
    await File('${f.path}.tmp').rename(f.path);
    final p = File('${m.dir}/peers.json');
    await File('${p.path}.tmp').writeAsString(jsonEncode(_fullPeers(m).take(_keptPeers).toList()));
    await File('${p.path}.tmp').rename(p.path);
  }

  /// At most this many peers are remembered across restarts.
  static const _keptPeers = 64;

  static Future<List<String>> _loadPeers(String dir) async {
    try {
      return (jsonDecode(await File('$dir/peers.json').readAsString()) as List).cast<String>();
    } on Object {
      return const [];
    }
  }

  /// Builds the corpus once every file is here, then packs and declares
  /// the partitions this member keeps.
  Future<void> _prepare(_Member m) async {
    if (m.corpus == null) {
      if (m.buildingCorpus) return;
      final wanted = {for (final (sha, _) in m.spec.files) sha};
      if (!wanted.every(m.files.containsKey)) return;
      m.buildingCorpus = true;
      try {
        final params = m.spec.params;
        final files = {for (final sha in wanted) sha: m.files[sha]!};
        final corpus = await _offBuildCorpus(params, files);
        if (corpus.rootHex != m.spec.corpusRoot) {
          m.corpusError = 'The copied files do not make the testnet\'s corpus.';
          return;
        }
        m.corpus = corpus;
        m.corpusError = null;
        m.node.keeper = Keeper(params: params, key: m.pubkey, corpus: corpus, folder: '${m.dir}/packed', files: files);
        for (var p = 0; p < corpus.partitions; p++) {
          if (m.node.keeper!.isPacked(p)) m.packed.add(p);
        }
      } finally {
        m.buildingCorpus = false;
      }
    }
    final keeper = m.node.keeper!;
    for (final p in m.keep.toList()..sort()) {
      // Preparing a copy is heavy: it waits for power like mining.
      if (_paused(m) != null) break;
      if (!m.packed.contains(p) && !m.packing.containsKey(p)) {
        m.packing[p] = 0;
        await _pack(keeper, p, (f) => m.packing[p] = f);
        m.packing.remove(p);
        m.packed.add(p);
      }
    }
    final st = m.node.state;
    // A keeper that missed a day (the device was off) declares everything
    // it keeps again, which starts it over.
    final restart = lapsed(st, m.pubkey, st.day);
    final declared = restart ? const <int, String>{} : st.declarations[m.pubkey] ?? const {};
    final missing = [
      for (final p in m.keep)
        if (m.packed.contains(p) && !declared.containsKey(p)) p,
    ];
    final waiting = m.node.waiting.any((t) => t.type == TxType.declare && t.from == m.pubkey);
    if (missing.isNotEmpty && !waiting) {
      m.node.submit(TxType.declare, {'circle': m.keepCircle, 'partitions': missing..sort()});
    }
  }

  // Work sent to another isolate goes through these, so the closure holds
  // only its arguments (a closure in a method would carry the method's
  // context, timers included, which cannot cross isolates).
  static Future<(List<(String, int)>, Corpus, Map<String, String>)> _offCorpusOfPaths(
    ChainParams params,
    List<String> paths,
  ) => Isolate.run(() => corpusOfPaths(params, paths));

  static Future<void> _offPack(Keeper keeper, int partition, SendPort progress) =>
      Isolate.run(() => keeper.pack(partition, onProgress: (d, t) => progress.send(d / t)));

  static Future<Corpus> _offBuildCorpus(ChainParams params, Map<String, String> files) =>
      Isolate.run(() => buildCorpus(params, files));

  /// Packs on a worker of its own, with progress, so this isolate keeps
  /// following the chain meanwhile.
  static Future<void> _pack(Keeper keeper, int partition, void Function(double) progress) async {
    final port = ReceivePort();
    final sub = port.listen((v) => progress(v as double));
    try {
      await _offPack(keeper, partition, port.sendPort);
    } finally {
      await sub.cancel();
      port.close();
    }
  }

  void _tick(_Member m) {
    m.ticks++;
    // The newest headers into the archive, a few below its top again in
    // case the chain turned.
    if (m.ticks % 5 == 0) _archive(m);
    if (m.ticks % 2 == 0 && m.wallet.update(m.node.state.outputs.raw)) unawaited(m.wallet.save());
    // Keeps meeting other full nodes: often while it knows none, then now
    // and then, so the network stays joined up as nodes come and go.
    if (m.ticks % (_fullPeers(m).isEmpty ? 30 : 300) == 1) _hello(m.address, m.rendezvous, full: true);
    // Declarations can be lost with a fork; keep checking.
    if (m.ticks % 30 == 0) {
      unawaited(_prepare(m));
      unawaited(_saveSnapshot(m));
    }
    final s = _state(m);
    final text = jsonEncode(s);
    if (text != m.lastState) {
      m.lastState = text;
      _out(['state', m.profileId, s]);
    }
  }

  Map<String, Object?> _state(_Member m) {
    final s = m.node.state;
    final params = m.spec.params;
    final circle = s.circles[m.keepCircle];
    final declared = s.declarations[m.pubkey] ?? const {};
    final proven = s.provenOn[m.pubkey] ?? const {};
    final copies = <int, int>{};
    for (final d in s.declarations.raw.values) {
      for (final p in d.keys) {
        copies[p] = (copies[p] ?? 0) + 1;
      }
    }
    final table = m.logs[m.keepCircle]?.payouts;
    final dayStart = s.genesisTick + s.day * params.dayTicks;
    return {
      'spec': m.spec.hash,
      'name': m.spec.corpusName,
      'founder': m.spec.founder == m.pubkey,
      'height': s.height,
      'day': s.day,
      // When the next day starts (it changes once a day, so the state is
      // not pushed every second for a countdown).
      'nextDayAt': (dayStart + params.dayTicks) * params.tickMillis,
      'dayLength': params.dayTicks * params.tickMillis ~/ 1000,
      'behind': m.node.currentTick - s.tick > params.blockTicks * 10,
      'peers': m.node.peerCount,
      'balance': s.balanceOf(m.pubkey),
      'private': m.wallet.balance.toInt(),
      'address': m.wallet.address.encoded,
      'pending': m.node.waiting.where((t) => t.from == m.pubkey).length,
      'mining': m.miningWanted,
      'paused': _paused(m),
      'standing': standingOf(s, m.pubkey).$2,
      'syncScore': syncScoreOf(s, m.keepCircle, m.pubkey, s.day),
      'keepCircle': m.keepCircle,
      // Every circle on the chain, with this member's part in it.
      'circles': [
        for (final e in s.circles.raw.entries)
          {
            'id': e.key,
            'name': e.value.name,
            'pool': e.value.pool,
            'admin': e.value.admin == m.pubkey,
            'moderator': e.value.moderators.contains(m.pubkey),
            'moderators': e.value.moderators.length,
            'live': s.isLive(e.key, s.tick),
            'keeping': m.keepCircle == e.key,
            'claimed': e.value.claimed[m.pubkey] ?? 0,
            'owed': m.logs[e.key]?.payouts[m.pubkey],
          },
      ],
      'circleFee': params.circleFee,
      'corpus': {
        'ready': m.corpus != null,
        'building': m.buildingCorpus,
        'error': m.corpusError,
        'files': m.spec.files.length,
        'present': m.spec.files.where((f) => m.files.containsKey(f.$1)).length,
      },
      'partitions': [
        for (var p = 0; p < m.spec.partitionSizes.length; p++)
          {
            'index': p,
            'bytes': m.spec.partitionSizes[p] * ChainParams.chunkBytes,
            'keep': m.keep.contains(p),
            'packing': m.packing[p],
            'packed': m.packed.contains(p),
            'declared': declared.containsKey(p),
            'provenToday': proven[p] == s.day,
            // A proof is due from the day after the declaration.
            'dueToday': declared.containsKey(p) && (s.declaredOn[m.pubkey]?[p] ?? s.day) < s.day,
            'copies': copies[p] ?? 0,
          },
      ],
      if (circle != null) 'reading': _reading(m, s),
      if (circle != null)
        'circle': {
          'id': m.spec.circleId,
          'name': circle.name,
          'pool': circle.pool,
          'admin': circle.admin == m.pubkey,
          'claimed': circle.claimed[m.pubkey] ?? 0,
          'payoutRoot': circle.payoutRoot,
          if (table != null) 'owed': table[m.pubkey] ?? 0,
        },
    };
  }

  /// How the circle is read, for this profile's server and its own reading:
  /// the allowance, who counts as a member, the open passes, and ours.
  Map<String, Object?> _reading(_Member m, ChainState s) {
    final circle = s.circles[m.keepCircle]!;
    final scores = _scoresOf(s, m.keepCircle);
    return {
      'passPrice': circle.passPrice,
      // Until the circle anchors its settings, the log's default.
      'freeAllowance': circle.anchoredAt >= 0 && circle.freeAllowance > 0 ? circle.freeAllowance : 1 << 30,
      'memberScore': circle.memberScore,
      'members': [
        for (final e in scores.entries)
          if (e.value > 0 && e.value >= circle.memberScore) e.key,
      ],
      'passes': {
        for (final e in s.passes.raw.entries)
          if (e.value.circle == m.keepCircle && e.value.activeAt(s.tick)) e.key: e.value.reader,
      },
      'myPass': [
        for (final e in s.passes.raw.entries)
          if (e.value.reader == m.pubkey && e.value.activeAt(s.tick))
            {'id': e.key, 'endsAt': e.value.expires * m.spec.params.tickMillis},
      ].firstOrNull,
      'ended': [
        for (final e in s.passes.raw.entries)
          if (!e.value.activeAt(s.tick) && !e.value.delivered.containsKey(m.pubkey)) e.key,
      ],
    };
  }

  /// Every member's sync score in [circle] as of today (a full node reads
  /// them all; nothing here needs proving).
  static Map<String, int> _scoresOf(ChainState s, String circle) {
    final prefix = '$circle ';
    return {
      for (final k in s.syncScores.raw.keys)
        if (k.startsWith(prefix)) k.substring(prefix.length): syncScoreOf(s, circle, k.substring(prefix.length), s.day),
    }..removeWhere((_, v) => v <= 0);
  }

  /// The admin splits what the pool earned since the last payout by the
  /// circle's policy: keepers by sync score, the corpus's contributor, and
  /// the admin and moderators.
  Future<Map<String, Object?>> _payout(_Member m, String circleId) async {
    final log = m.logs[circleId];
    if (log == null || log.admin != m.pubkey) return {'error': 'Only the circle\'s admin pays out its pool.'};
    final s = m.node.state;
    final circle = s.circles[circleId]!;
    final owed = log.payouts.values.fold<int>(0, (a, b) => a + b) - circle.claimed.values.fold<int>(0, (a, b) => a + b);
    final free = circle.pool - owed;
    if (free <= 0) return {'error': 'Nothing new in the pool to pay out.'};
    final scores = _scoresOf(s, circleId);
    final totals = distribute(free, log.policy.payoutShares, {
      'keepers': Map.of(scores),
      'contributors': {m.spec.corpusOwner: 1},
      'moderators': {log.admin: 1, for (final k in log.moderators) k: 1},
    }, log.payouts);
    await log.writeWith(m.signer, LogType.payout, {'table': totals});
    await _saveLog(m, circleId);
    return {'paidOut': free};
  }

  /// A member claims what the anchored payout table owes it.
  Future<Map<String, Object?>> _claim(_Member m, String circleId) async {
    final circle = m.node.state.circles[circleId];
    if (circle == null) return {'error': 'No such circle on the chain.'};
    final r = await _claimBody(m.spec, circleId, circle, m.pubkey, m.logs[circleId], m.address, _fullPeers(m).firstOrNull);
    if (r['body'] case final Map body) {
      await m.node.submit(TxType.claim, body.cast<String, Object?>());
      return {'claimed': r['owed']};
    }
    return r;
  }

  /// Creates a circle on the chain (the fee is burned) and its log, run by
  /// this member as admin and moderator, listing the test network's files
  /// so its keepers can earn. The node anchors it by itself.
  Future<Map<String, Object?>> _createCircle(_Member m, String id, String name) async {
    final s = m.node.state;
    if (!RegExp(r'^[a-z0-9][a-z0-9-]{2,62}$').hasMatch(id)) {
      return {'error': 'A circle id is 3 to 63 lowercase letters, digits or dashes.'};
    }
    if (s.circles.containsKey(id)) return {'error': 'A circle with that id exists.'};
    if (s.balanceOf(m.pubkey) < m.spec.params.circleFee) {
      return {'error': 'Creating a circle burns ${m.spec.params.circleFee ~/ ChainParams.grainsPerMarca} marcas.'};
    }
    final log = CircleLog(id, admin: m.pubkey);
    await log.writeWith(m.signer, LogType.appoint, {'key': m.pubkey});
    await log.writeWith(m.signer, LogType.collection, {
      'id': '$id-files',
      'partitions': [for (var i = 0; i < m.spec.partitionSizes.length; i++) i],
      'root': m.spec.corpusRoot,
    });
    m.logs[id] = log;
    await _saveLog(m, id);
    await m.node.submit(TxType.createCircle, {'circle': id, 'name': name.trim().isEmpty ? id : name.trim()});
    return {};
  }

  /// A claim of what the anchored payout table owes [me] in [circle]: the
  /// log comes from [log] when it is ours, else from the founder.
  Future<Map<String, Object?>> _claimBody(
    TestnetSpec spec,
    String circleId,
    CircleState circle,
    String me,
    CircleLog? log,
    String address,
    String? founderAddress,
  ) async {
    if (circle.logHead.isEmpty || circle.payoutRoot.isEmpty) return {'error': 'The circle has not paid out yet.'};
    if (log == null || log.head != circle.logHead) {
      // The anchored log, from the founder, replayed up to the anchor.
      // From where the circle's anchor says, or the founder's for the
      // genesis circle.
      final at = circle.logAt.isNotEmpty ? circle.logAt : founderAddress;
      if (at == null) return {'error': 'Nobody is known to hold the circle\'s log.'};
      final reply = await _ask(address, at, {'t': 'getLog', 'circle': circleId});
      final entries = [for (final e in reply['entries'] as List) LogEntry.fromJson(e as Map)];
      final upTo = entries.indexWhere((e) => e.id == circle.logHead);
      if (upTo < 0) return {'error': 'The circle\'s log does not reach its anchor yet.'};
      log = CircleLog.replay(circleId, entries.first.author, entries.take(upTo + 1));
    }
    final table = log.payoutTable();
    if (toHex(table.root) != circle.payoutRoot) {
      return {'error': 'The payout table is not anchored yet; try again soon.'};
    }
    if (!table.totals.containsKey(me)) return {'error': 'Nothing to claim.'};
    final owed = table.totals[me]! - (circle.claimed[me] ?? 0);
    if (owed <= 0) return {'error': 'Nothing to claim.'};
    if (circle.pool < owed) return {'error': 'The pool holds less than the claim.'};
    return {'body': table.claimBody(me), 'owed': owed};
  }

  Future<void> _close(_Member m) async {
    m.timer?.cancel();
    await m.node.stop();
    await _saveSnapshot(m);
  }

  Future<void> stop() async {
    for (final m in _members.values) {
      await _close(m);
    }
    _members.clear();
    for (final m in _lights.values) {
      m.timer?.cancel();
      await m.light.stop();
    }
    _lights.clear();
  }
}

/// Grains from a decimal amount of marcas ("12.5"), or null.
int? grainsOf(String marcas) {
  final m = RegExp(r'^\s*(\d+)(?:[.,](\d{1,8}))?\s*$').firstMatch(marcas);
  if (m == null) return null;
  final whole = int.parse(m.group(1)!);
  final frac = (m.group(2) ?? '').padRight(8, '0');
  return whole * ChainParams.grainsPerMarca + int.parse(frac.isEmpty ? '0' : frac);
}
