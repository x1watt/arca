// The chain's own isolate (docs/performance.md, 3.15): checking a block or
// a holding proof costs an Argon2id, and packing a partition costs one per
// chunk, so none of it runs on the core isolate. The core forwards chain
// messages (first byte 0xC1) between the network and this isolate, sends
// it commands, and keeps the latest state it reports for the UI.
//
// One member per profile that takes part: its chain node on the profile's
// I2P address, its steward (packed partitions), and for the admin the
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
import 'signer.dart';
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
  final _parts = Reassembly();
  final _waiting = <String, Completer<Map>>{};
  final _signing = <int, Completer<Uint8List>>{};
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
        if (msg != null && msg['id'] != null && (msg['t'] == 'spec' || msg['t'] == 'log')) {
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
        _members[a['profile']]!.node.mining = a['on'] as bool;
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
    if (_members.containsKey(profile)) return;
    final spec = TestnetSpec((a['spec'] as Map).cast<String, Object?>());
    final dir = a['dir'] as String;
    await Directory(dir).create(recursive: true);
    // The key stays in the core; signatures are asked of it.
    final signer = _RemoteSigner(this, profile, a['pubkey'] as String);
    final address = a['address'] as String;
    final genesis = spec.genesis();
    final peers = (a['peers'] as List).cast<String>();
    final snap = File('$dir/snapshot.json');
    ChainNode node;
    if (await snap.exists()) {
      node = ChainNode.fromSnapshot(
        jsonDecode(await snap.readAsString()) as Map,
        params: spec.params,
        genesisRoot: genesis.rootHex,
        address: address,
        link: _link,
        signer: signer,
        peers: peers,
      );
    } else {
      node = ChainNode(
        params: spec.params,
        genesis: genesis,
        address: address,
        link: _link,
        signer: signer,
        peers: peers,
      );
    }
    final m = _Member(profile, signer, address, a['arcaAddress'] as String, dir, spec, node)
      ..keep = {...(a['keep'] as List? ?? const []).cast<int>()}
      ..files = (a['files'] as Map? ?? const {}).cast<String, String>()
      ..founderAddress = a['founderAddress'] as String?;
    node.mining = a['mining'] as bool? ?? true;
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
        m.node.steward = Steward(
          params: params,
          key: m.pubkey,
          corpus: corpus,
          folder: '${m.dir}/packed',
          files: files,
        );
        for (var p = 0; p < corpus.partitions; p++) {
          if (m.node.steward!.isPacked(p)) m.packed.add(p);
        }
      } finally {
        m.buildingCorpus = false;
      }
    }
    final steward = m.node.steward!;
    for (final p in m.keep.toList()..sort()) {
      if (!m.packed.contains(p) && !m.packing.containsKey(p)) {
        m.packing[p] = 0;
        await _pack(steward, p, (f) => m.packing[p] = f);
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

  static Future<void> _offPack(Steward steward, int partition, SendPort progress) =>
      Isolate.run(() => steward.pack(partition, onProgress: (d, t) => progress.send(d / t)));

  static Future<Corpus> _offBuildCorpus(ChainParams params, Map<String, String> files) =>
      Isolate.run(() => buildCorpus(params, files));

  /// Packs on a worker of its own, with progress, so this isolate keeps
  /// following the chain meanwhile.
  static Future<void> _pack(Steward steward, int partition, void Function(double) progress) async {
    final port = ReceivePort();
    final sub = port.listen((v) => progress(v as double));
    try {
      await _offPack(steward, partition, port.sendPort);
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
      'mining': m.node.mining,
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

  /// The admin splits what the pool earned since the last payout by the
  /// circle's policy: stewards by sync score, the corpus's contributor, and
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
      'stewards': Map.of(scores),
      'contributors': {m.spec.corpusOwner: 1},
      'moderators': {log.admin: 1, for (final k in log.moderators) k: 1},
    }, log.payouts);
    await log.writeWith(m.signer, LogType.payout, {'table': totals});
    await _saveLog(m);
    return {'paidOut': free};
  }

  /// A member claims what the anchored payout table owes it.
  Future<Map<String, Object?>> _claim(_Member m) async {
    final s = m.node.state;
    final circle = s.circles[m.spec.circleId]!;
    if (circle.logHead.isEmpty || circle.payoutRoot.isEmpty) return {'error': 'The circle has not paid out yet.'};
    CircleLog? log = m.log;
    if (log == null || log.head != circle.logHead) {
      // The anchored log, from the founder, replayed up to the anchor.
      final founder = m.spec.founder;
      final from = m.founderAddress;
      if (from == null) return {'error': 'The founder\'s address is unknown.'};
      final reply = await _ask(m.address, from, {'t': 'getLog'});
      final entries = [for (final e in reply['entries'] as List) LogEntry.fromJson(e as Map)];
      final upTo = entries.indexWhere((e) => e.id == circle.logHead);
      if (upTo < 0) return {'error': 'The circle\'s log does not reach its anchor yet.'};
      log = CircleLog.replay(m.spec.circleId, founder, entries.take(upTo + 1));
    }
    final table = log.payoutTable();
    if (toHex(table.root) != circle.payoutRoot) {
      return {'error': 'The payout table is not anchored yet; try again soon.'};
    }
    if (!table.totals.containsKey(m.pubkey)) return {'error': 'Nothing to claim.'};
    final owed = table.totals[m.pubkey]! - (circle.claimed[m.pubkey] ?? 0);
    if (owed <= 0) return {'error': 'Nothing to claim.'};
    if (circle.pool < owed) return {'error': 'The pool holds less than the claim.'};
    m.node.submit(TxType.claim, table.claimBody(m.pubkey));
    return {'claimed': owed};
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
