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
import 'dart:typed_data';

import '../crypto/hex.dart';
import '../transport/link.dart';
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
import 'testnet.dart';
import 'tx.dart';
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
  _LightMember(this.profileId, this.signer, this.address, this.invite, this.spec, this.light, this.founderAddress);

  final String profileId;
  final Signer signer;
  final String address;
  final String invite;
  final TestnetSpec spec;
  final LightClient light;
  final String? founderAddress;

  int balance = 0;
  int nonce = 0;
  int standing = 0;
  int syncScore = 0;
  CircleState? circle;
  final pending = <Tx>[];
  String readAt = '';
  bool reading = false;
  String lastState = '';
  Timer? timer;
  int ticks = 0;

  String get pubkey => signer.publicKey;
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
  CircleLog? log;

  /// The founder's I2P address (null for the founder): where the circle's
  /// log comes from.
  String? founderAddress;
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

  /// Why heavy work waits for [m], or null when it may run. Daily proofs
  /// are not held back: a missed one loses everything.
  String? _paused(_Member m) {
    if (_onlyCharging && !_charging) return 'charging';
    if (_onlyUnmetered && !_unmetered) return 'network';
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
        // Answers to this worker's own requests (spec, log).
        final msg = _parts.add(inbound);
        if (msg != null && msg['id'] != null && const {'spec', 'log', 'checkpoint', 'snapshot'}.contains(msg['t'])) {
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

  Future<Map<String, Object?>> _command(String name, Map<String, Object?> a) async {
    final light = _lights[a['profile']];
    if (light != null && name != 'join') return _lightCommand(light, name, a);
    switch (name) {
      case 'build':
        // A founder's spec from their collection's files.
        final params = a['params'] == null ? ChainParams.testnet : ChainParams.fromJson(a['params'] as Map);
        final paths = (a['paths'] as List).cast<String>();
        final (files, corpus, _) = await _offCorpusOfPaths(params, paths);
        final spec = TestnetSpec.create(
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
      case 'fetchSpec':
        final reply = await _ask(a['from'] as String, a['to'] as String, {'t': 'getSpec'});
        final spec = TestnetSpec((reply['spec'] as Map).cast<String, Object?>());
        if (spec.hash != a['hash']) return {'error': 'The testnet this address serves is not the one in the invite.'};
        return {'spec': spec.json};
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
        for (final m in _members.values) {
          _applyPower(m);
          unawaited(_prepare(m));
        }
        return {};
      case 'send':
        final m = _members[a['profile']]!;
        final amount = a['amount'] as int;
        if (amount <= 0) return {'error': 'Enter an amount above zero.'};
        if (m.node.state.balanceOf(m.pubkey) < amount) return {'error': 'The balance is not enough for that.'};
        m.node.submit(TxType.transfer, {'to': a['to'], 'amount': amount});
        return {};
      case 'payout':
        return _payout(_members[a['profile']]!);
      case 'reading':
        // The admin's reading settings, into the circle's log and, with the
        // next anchor, onto the chain.
        final m = _members[a['profile']]!;
        final log = m.log;
        if (log == null || log.admin != m.pubkey) return {'error': 'Only the circle\'s admin sets how it is read.'};
        final policy = {...log.policy.toJson(), ...(a['reading'] as Map).cast<String, Object?>()};
        try {
          await log.writeWith(m.signer, LogType.policy, policy);
        } on LogError catch (e) {
          return {'error': e.message};
        }
        await _saveLog(m);
        return {};
      case 'buyPass':
        final m = _members[a['profile']]!;
        final circle = m.node.state.circles[m.spec.circleId];
        if (circle == null || circle.passPrice <= 0) return {'error': 'This circle sells no passes.'};
        if (m.node.state.balanceOf(m.pubkey) < circle.passPrice) {
          return {'error': 'The balance is not enough for a pass.'};
        }
        final tx = await m.node.submit(TxType.buyPass, {'circle': m.spec.circleId});
        return {'pass': tx.id};
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
        return _claim(_members[a['profile']]!);
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
  Future<Map> _ask(String from, String to, Map<String, Object?> msg) async {
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
      return await c.future.timeout(const Duration(seconds: 90));
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
    final peers = (a['peers'] as List).cast<String>();
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
    // A newcomer starts from the founder's recent state, not from genesis:
    // nodes keep no blocks older than their own snapshot.
    final founder = a['founderAddress'] as String?;
    if (node == null && founder != null) {
      final boot = await _bootstrap(spec, address, founder);
      if (boot != null) {
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
      ..keep = {...(a['keep'] as List? ?? const []).cast<int>()}
      ..files = (a['files'] as Map? ?? const {}).cast<String, String>()
      ..founderAddress = a['founderAddress'] as String?;
    m.miningWanted = a['mining'] as bool? ?? true;
    _applyPower(m);
    // The founder keeps the circle's log.
    final logFile = File('$dir/log.json');
    if (await logFile.exists()) {
      m.log = CircleLog.replay(spec.circleId, spec.founder, [
        for (final e in jsonDecode(await logFile.readAsString()) as List) LogEntry.fromJson(e as Map),
      ]);
    } else if (spec.founder == node.key) {
      // The admin appoints itself moderator: moderators accept collections.
      final log = CircleLog(spec.circleId, admin: spec.founder);
      await log.writeWith(signer, LogType.appoint, {'key': spec.founder});
      await log.writeWith(signer, LogType.collection, {
        'id': 'corpus',
        'partitions': [for (var i = 0; i < spec.partitionSizes.length; i++) i],
        'root': spec.corpusRoot,
      });
      m.log = log;
      await _saveLog(m);
    }
    Future<Map<String, Object?>?> answer(String from, Map msg) async {
      switch (msg['t']) {
        case 'getSpec':
          return {'t': 'spec', 'spec': spec.json};
        case 'getLog' when m.log != null:
          return {
            't': 'log',
            'entries': [for (final e in m.log!.entries) e.toJson()],
          };
      }
      return null;
    }

    node.answer = answer;
    node.anchorBody = (circle) => circle == spec.circleId ? m.log?.anchorBody() : null;
    _members[profile] = m;
    node.start();
    m.timer = Timer.periodic(const Duration(seconds: 1), (_) => _tick(m));
    unawaited(_prepare(m));
  }

  // ---- Light mode ----

  void _joinLight(Map<String, Object?> a) {
    final profile = a['profile'] as String;
    final spec = TestnetSpec((a['spec'] as Map).cast<String, Object?>());
    final founder = a['founderAddress'] as String?;
    final light = LightClient(
      params: spec.params,
      genesisRoot: spec.genesis().rootHex,
      genesisTick: spec.genesisTick,
      address: a['address'] as String,
      link: _link,
      peers: [?founder],
    );
    final m = _LightMember(
      profile,
      _RemoteSigner(this, profile, a['pubkey'] as String),
      a['address'] as String,
      // A light node serves no spec: its invite names the founder.
      a['founderArca'] == null ? '' : TestnetSpec.invite(spec.hash, a['founderArca'] as String),
      spec,
      light,
      founder,
    );
    _lights[profile] = m;
    light.start();
    m.timer = Timer.periodic(const Duration(seconds: 1), (_) => _lightTick(m));
  }

  Future<void> _lightTick(_LightMember m) async {
    m.ticks++;
    // Waiting transactions again every ten seconds: a full node may not
    // have heard them.
    if (m.ticks % 10 == 0) {
      for (final t in m.pending) {
        m.light.broadcast({'t': 'tx', 'tx': t.toJson()});
      }
    }
    final head = m.light.headHash;
    if (!m.reading && head.isNotEmpty && (head != m.readAt || m.ticks % 15 == 0)) {
      m.reading = true;
      try {
        await _lightRead(m, head);
        m.readAt = head;
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

  Future<void> _lightRead(_LightMember m, String at) async {
    final me = m.pubkey;
    final balances = await m.light.read('balances', [me], at: at);
    final nonces = await m.light.read('nonces', [me], at: at);
    final circles = await m.light.read('circles', [m.spec.circleId], at: at);
    final standing = await m.light.read('standing', [me], at: at);
    final sync = await m.light.read('sync', [m.spec.circleId], at: at);
    m.balance = int.tryParse(balances[me]?.value ?? '') ?? 0;
    m.nonce = int.tryParse(nonces[me]?.value ?? '') ?? 0;
    final c = circles[m.spec.circleId]?.value;
    m.circle = c == null ? null : CircleState.fromJson(jsonDecode(c) as Map);
    m.standing = int.tryParse(standing[me]?.value ?? '') ?? 0;
    final scores = sync[m.spec.circleId]?.value;
    m.syncScore = scores == null ? 0 : ((jsonDecode(scores) as Map)[me] as int? ?? 0);
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
      'invite': m.invite,
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
        final amount = a['amount'] as int;
        if (amount <= 0) return {'error': 'Enter an amount above zero.'};
        final spent = m.pending
            .where((t) => t.type == TxType.transfer)
            .fold<int>(0, (n, t) => n + (t.body['amount'] as int));
        if (m.balance - spent < amount) return {'error': 'The balance is not enough for that.'};
        await _lightSubmit(m, TxType.transfer, {'to': a['to'], 'amount': amount});
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
        final r = await _claimBody(m.spec, c, m.pubkey, null, m.address, m.founderAddress);
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

  /// The founder's head header (a checkpoint, trusted on first use like the
  /// invite itself) and the state after it, every namespace checked against
  /// the header's state root. Null when the chain has no block yet.
  Future<Map<String, Object?>?> _bootstrap(TestnetSpec spec, String from, String to) async {
    final cp = await _ask(from, to, {'t': 'getCheckpoint'});
    if (cp['header'] == null) return null;
    final header = Header.fromJson(cp['header'] as Map);
    if (!header.signed) throw StateError('The founder\'s checkpoint is not signed.');
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
      throw StateError('The founder\'s state is not the one its checkpoint names.');
    }
    for (var i = 0; i < ChainState.namespaces.length; i++) {
      if (toHex(smtRoot(entries[ChainState.namespaces[i]]!)) != roots[i]) {
        throw StateError('The founder\'s ${ChainState.namespaces[i]} do not match their root.');
      }
    }
    return {'block': header.asBlock.toJson(), 'work': cp['work'], 'state': entries};
  }

  Future<void> _saveLog(_Member m) async {
    final f = File('${m.dir}/log.json');
    await File('${f.path}.tmp').writeAsString(jsonEncode([for (final e in m.log!.entries) e.toJson()]));
    await File('${f.path}.tmp').rename(f.path);
  }

  Future<void> _saveSnapshot(_Member m) async {
    final f = File('${m.dir}/snapshot.json');
    await File('${f.path}.tmp').writeAsString(jsonEncode(m.node.snapshot()));
    await File('${f.path}.tmp').rename(f.path);
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
    final declared = m.node.state.declarations[m.pubkey] ?? const {};
    final missing = [
      for (final p in m.keep)
        if (m.packed.contains(p) && !declared.containsKey(p)) p,
    ];
    final waiting = m.node.waiting.any((t) => t.type == TxType.declare && t.from == m.pubkey);
    if (missing.isNotEmpty && !waiting) {
      m.node.submit(TxType.declare, {'circle': m.spec.circleId, 'partitions': missing..sort()});
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
    final circle = s.circles[m.spec.circleId];
    final declared = s.declarations[m.pubkey] ?? const {};
    final proven = s.provenOn[m.pubkey] ?? const {};
    final copies = <int, int>{};
    for (final d in s.declarations.raw.values) {
      for (final p in d.keys) {
        copies[p] = (copies[p] ?? 0) + 1;
      }
    }
    final table = m.log?.payouts;
    final dayStart = s.genesisTick + s.day * params.dayTicks;
    return {
      'spec': m.spec.hash,
      'invite': TestnetSpec.invite(m.spec.hash, m.arcaAddress),
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
      'pending': m.node.waiting.where((t) => t.from == m.pubkey).length,
      'mining': m.miningWanted,
      'paused': _paused(m),
      'standing': s.standing[m.pubkey] ?? 0,
      'syncScore': s.syncScores[m.spec.circleId]?[m.pubkey] ?? 0,
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
    final circle = s.circles[m.spec.circleId]!;
    final scores = s.syncScores[m.spec.circleId] ?? const <String, int>{};
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
          if (e.value.circle == m.spec.circleId && e.value.activeAt(s.tick)) e.key: e.value.reader,
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

  /// The admin splits what the pool earned since the last payout by the
  /// circle's policy: keepers by sync score, the corpus's contributor, and
  /// the admin and moderators.
  Future<Map<String, Object?>> _payout(_Member m) async {
    final log = m.log;
    if (log == null || log.admin != m.pubkey) return {'error': 'Only the circle\'s admin pays out its pool.'};
    final s = m.node.state;
    final circle = s.circles[m.spec.circleId]!;
    final owed = log.payouts.values.fold<int>(0, (a, b) => a + b) - circle.claimed.values.fold<int>(0, (a, b) => a + b);
    final free = circle.pool - owed;
    if (free <= 0) return {'error': 'Nothing new in the pool to pay out.'};
    final scores = s.syncScores[m.spec.circleId] ?? const {};
    final totals = distribute(free, log.policy.payoutShares, {
      'keepers': Map.of(scores),
      'contributors': {m.spec.corpusOwner: 1},
      'moderators': {log.admin: 1, for (final k in log.moderators) k: 1},
    }, log.payouts);
    await log.writeWith(m.signer, LogType.payout, {'table': totals});
    await _saveLog(m);
    return {'paidOut': free};
  }

  /// A member claims what the anchored payout table owes it.
  Future<Map<String, Object?>> _claim(_Member m) async {
    final r = await _claimBody(
      m.spec,
      m.node.state.circles[m.spec.circleId]!,
      m.pubkey,
      m.log,
      m.address,
      m.founderAddress,
    );
    if (r['body'] case final Map body) {
      await m.node.submit(TxType.claim, body.cast<String, Object?>());
      return {'claimed': r['owed']};
    }
    return r;
  }

  /// A claim of what the anchored payout table owes [me] in [circle]: the
  /// log comes from [log] when it is ours, else from the founder.
  Future<Map<String, Object?>> _claimBody(
    TestnetSpec spec,
    CircleState circle,
    String me,
    CircleLog? log,
    String address,
    String? founderAddress,
  ) async {
    if (circle.logHead.isEmpty || circle.payoutRoot.isEmpty) return {'error': 'The circle has not paid out yet.'};
    if (log == null || log.head != circle.logHead) {
      // The anchored log, from the founder, replayed up to the anchor.
      if (founderAddress == null) return {'error': 'The founder\'s address is unknown.'};
      final reply = await _ask(address, founderAddress, {'t': 'getLog'});
      final entries = [for (final e in reply['entries'] as List) LogEntry.fromJson(e as Map)];
      final upTo = entries.indexWhere((e) => e.id == circle.logHead);
      if (upTo < 0) return {'error': 'The circle\'s log does not reach its anchor yet.'};
      log = CircleLog.replay(spec.circleId, spec.founder, entries.take(upTo + 1));
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
