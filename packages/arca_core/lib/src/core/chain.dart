part of 'core_service.dart';

// The core's side of the chain (docs/architecture.md, 10): the chain runs
// in its own isolate (chain/worker.dart); the core starts it, forwards
// chain messages between it and the network, keeps each profile's choice
// of testnet in `<profile>/chain/config.json`, and keeps the latest state
// the worker reports, so building the UI's state reads no disk.

extension _Chain on CoreService {
  File _chainConfigFile(String id) => File('${_store.profileDir(id).path}/chain/config.json');

  Future<Map<String, Object?>?> _chainConfig(String id) async {
    final f = _chainConfigFile(id);
    if (!await f.exists()) return null;
    return (jsonDecode(await f.readAsString()) as Map).cast<String, Object?>();
  }

  Future<void> _saveChainConfig(String id, Map<String, Object?> config) async {
    _chainHas.add(id);
    final f = _chainConfigFile(id);
    await f.parent.create(recursive: true);
    await File('${f.path}.tmp').writeAsString(jsonEncode(config));
    await File('${f.path}.tmp').rename(f.path);
  }

  Future<SendPort> _chainWorker() => _chainPort ??= () async {
    final inbox = ReceivePort();
    final ready = Completer<SendPort>();
    inbox.listen((msg) {
      if (msg is SendPort) {
        ready.complete(msg);
        return;
      }
      final m = msg as List;
      switch (m[0]) {
        case 'reply':
          _chainReplies.remove(m[1])?.complete((m[2] as Map).cast<String, Object?>());
        case 'send':
          unawaited(net.backend.link.send(m[1] as String, m[2] as Uint8List, from: m[3] as String));
        case 'state':
          if (m[2] == null) {
            _chainStates.remove(m[1]);
          } else {
            _chainStates[m[1] as String] = (m[2] as Map).cast<String, Object?>();
          }
          if (m[1] == _store.active?.id) _push();
        case 'sign':
          // The only use of a key for the chain: the signature leaves, the
          // key does not.
          final (id, profile, message) = (m[1] as int, m[2] as String, m[3] as Uint8List);
          unawaited(
            _secretKey(
              profile,
            ).then((key) async => (await _chainPort!).send(['signed', id, schnorrSign(key, message)])),
          );
        case 'stopped':
          _chainStopped?.complete();
          inbox.close();
      }
    });
    await Isolate.spawn(chainWorkerMain, inbox.sendPort, debugName: 'chain');
    return ready.future;
  }();

  Future<Map<String, Object?>> _chainCmd(String name, Map<String, Object?> args) async {
    final port = await _chainWorker();
    final id = _chainNextId++;
    final c = Completer<Map<String, Object?>>();
    _chainReplies[id] = c;
    port.send(['cmd', id, name, args]);
    return c.future;
  }

  /// Chain messages for the profiles in the chain go to the worker.
  Future<void> _chainForward() async {
    if (_chainInbound != null || net.state != NetState.up) return;
    final port = await _chainWorker();
    _chainInbound = net.backend.link.incoming
        .where((m) => m.bytes.isNotEmpty && m.bytes[0] == chainTag && _chainAddresses.contains(m.to))
        .listen((m) => port.send(['in', m.from, m.to, m.bytes]));
  }

  /// Puts every online profile with a testnet into the chain.
  Future<void> _chainResumeAll() async {
    if (_closing || net.state != NetState.up) return;
    for (final p in _store.profiles) {
      if (!_chainJoined.contains(p.id) && net.addressOf(p.id) != null) await _chainResume(p.id);
    }
  }

  Future<void> _chainResume(String id) async {
    try {
      await _chainResumeUnsafe(id);
      _chainErrors.remove(id);
    } catch (e) {
      // Shown on the wallet's waiting page; tried again on the next change.
      _chainJoined.remove(id);
      _chainErrors[id] = '$e';
      stderr.writeln('chain: could not start for $id: $e');
      _push();
    }
  }

  Future<void> _chainResumeUnsafe(String id) async {
    final address = net.addressOf(id);
    if (address == null || _chainJoined.contains(id) || _chainNone.contains(id)) return;
    final config = await _chainConfig(id);
    if (config == null) {
      // Checked once; starting or joining a testnet clears it.
      _chainNone.add(id);
      return;
    }
    _chainJoined.add(id);
    _chainAddresses.add(address);
    await _chainForward();
    final spec = TestnetSpec((config['spec'] as Map).cast<String, Object?>());
    final founderI2p = config['founderI2p'] as String?;
    final p = _store.profiles.firstWhere((x) => x.id == id);
    final joined = await _chainCmd('join', {
      'profile': id,
      'pubkey': p.pubkey,
      'address': address,
      'arcaAddress': arcaAddress(p.npub, address),
      'dir': _chainConfigFile(id).parent.path,
      'spec': spec.json,
      'keep': config['keep'],
      'mining': config['mining'] ?? true,
      'founderAddress': founderI2p,
      'peers': [?founderI2p],
      'files': await _chainFiles(id, spec),
    });
    if (joined['error'] != null) throw StateError(joined['error'] as String);
    _background(_chainWatchFiles(id, spec));
  }

  /// The corpus files this profile holds, by SHA-256: the founder's own
  /// collection, or the copy kept of it.
  Future<Map<String, String>> _chainFiles(String id, TestnetSpec spec) async {
    final wanted = {for (final (sha, _) in spec.files) sha};
    final out = <String, String>{};
    if (spec.corpusOwner == _pubkeyOf(id)) {
      final lib = await _library(id);
      for (final c in lib.collections.where((c) => c.id == spec.corpusCollection)) {
        for (final f in c.files.where((f) => wanted.contains(f.sha256))) {
          out[f.sha256] = '${c.folder}/${f.path}';
        }
      }
    } else {
      final store = await _syncStore(id);
      for (final s in store.items.where((x) => x.owner == spec.corpusOwner && x.collection == spec.corpusCollection)) {
        for (final e in s.files.entries.where((e) => wanted.contains(e.value))) {
          if (await File('${s.folder}/${e.key}').exists()) out[e.value] = '${s.folder}/${e.key}';
        }
      }
    }
    return out;
  }

  /// Until every corpus file is here (a joiner's copy still arriving), tells
  /// the worker what arrived, every few seconds.
  Future<void> _chainWatchFiles(String id, TestnetSpec spec) async {
    var sent = -1;
    while (!_closing && _chainJoined.contains(id)) {
      final files = await _chainFiles(id, spec);
      if (files.length != sent) {
        sent = files.length;
        await _chainCmd('files', {'profile': id, 'files': files});
      }
      if (files.length == spec.files.length) return;
      await Future<void>.delayed(const Duration(seconds: 5));
    }
  }

  /// Starts a testnet with one of the active profile's collections as its
  /// corpus.
  Future<Map<String, Object?>?> _chainStart(String collection, {Map<String, Object?>? params}) async {
    final id = _activeId;
    if (await _chainConfig(id) != null) return {'error': 'This profile already takes part in a testnet.'};
    final lib = await _library(id);
    final col = lib.collections.where((c) => c.id == collection).firstOrNull;
    if (col == null) return {'error': 'No such collection.'};
    if (col.files.isEmpty) return {'error': 'That collection has no files yet.'};
    final built = await _chainCmd('build', {
      'paths': [for (final f in col.files) '${col.folder}/${f.path}'],
      'founder': _pubkeyOf(id),
      'collection': col.id,
      'name': col.name,
      'params': ?params,
    });
    if (built['error'] != null) return built;
    final spec = TestnetSpec((built['spec'] as Map).cast<String, Object?>());
    await _saveChainConfig(id, {
      'spec': spec.json,
      'keep': [for (var i = 0; i < spec.partitionSizes.length; i++) i],
      'mining': true,
    });
    _chainNone.remove(id);
    await _chainResume(id);
    return null;
  }

  /// Joins the testnet an invite names: fetches its spec from the address
  /// in the invite, follows the founder and keeps a copy of the corpus.
  Future<Map<String, Object?>?> _chainJoin(String invite) async {
    final id = _activeId;
    if (await _chainConfig(id) != null) return {'error': 'This profile already takes part in a testnet.'};
    final parsed = TestnetSpec.parseInvite(invite);
    if (parsed == null) return {'error': 'That is not an Arca testnet invite.'};
    final (hash, arca) = parsed;
    final (pubkey, i2p) = parseArcaAddress(arca);
    if (pubkey == _pubkeyOf(id)) return {'error': 'That is your own invite.'};
    final me = net.addressOf(id);
    if (me == null) return {'error': 'This profile is not online yet.'};
    await _chainForward();
    // The spec comes back to our address, which the worker must hear.
    _chainAddresses.add(me);
    final got = await _chainCmd('fetchSpec', {'from': me, 'to': i2p, 'hash': hash});
    if (got['error'] != null) {
      _chainAddresses.remove(me);
      return got;
    }
    final spec = TestnetSpec((got['spec'] as Map).cast<String, Object?>());
    // Keep a copy of the corpus: follow its owner and sync the collection.
    final fs = await _followStore(id);
    var f = fs.byPubkey(spec.corpusOwner);
    if (f == null) {
      f = Follow(pubkey: spec.corpusOwner, address: i2p);
      fs.follows.add(f);
      await fs.save();
    }
    await _refreshFollow(id, f);
    if (!f.collections.containsKey(spec.corpusCollection)) {
      return {'error': 'Could not read the corpus collection from the founder. Try again when both are online.'};
    }
    final s = await _syncEntry(id, f, spec.corpusCollection);
    _background(_syncOne(id, f, s));
    await _saveChainConfig(id, {
      'spec': spec.json,
      'founderI2p': i2p,
      'keep': [for (var i = 0; i < spec.partitionSizes.length; i++) i],
      'mining': true,
    });
    _chainAddresses.remove(me);
    _chainNone.remove(id);
    await _chainResume(id);
    return null;
  }

  Future<Map<String, Object?>?> _chainLeave() async {
    final id = _activeId;
    if (_chainJoined.remove(id)) await _chainCmd('leave', {'profile': id});
    final address = net.addressOf(id);
    if (address != null) _chainAddresses.remove(address);
    final f = _chainConfigFile(id);
    if (await f.exists()) await f.delete();
    _chainStates.remove(id);
    _chainHas.remove(id);
    return null;
  }

  Future<Map<String, Object?>?> _chainSetting(String key, Object? value) async {
    final config = await _chainConfig(_activeId);
    if (config == null) return {'error': 'This profile takes part in no testnet.'};
    config[key] = value;
    await _saveChainConfig(_activeId, config);
    return null;
  }

  /// A key from an npub, an Arca address or hex.
  String? _keyOf(String who) {
    final t = who.trim();
    try {
      if (t.startsWith('arca:')) return parseArcaAddress(t).$1;
      if (t.startsWith('npub1')) return toHex(decodeEntity(t, 'npub'));
    } catch (_) {
      return null;
    }
    return RegExp(r'^[0-9a-f]{64}$').hasMatch(t) ? t : null;
  }

  Future<Map<String, Object?>?> _chainCommand(String command, Map<String, Object?> args) async {
    final id = _activeId;
    switch (command) {
      case 'chainStart':
        // Tests pass faster rules; the app always uses the testnet's.
        return _chainStart(args['collection'] as String, params: (args['params'] as Map?)?.cast<String, Object?>());
      case 'chainJoin':
        return _chainJoin(args['invite'] as String);
      case 'chainLeave':
        return _chainLeave();
      case 'chainSend':
        final to = _keyOf(args['to'] as String? ?? '');
        if (to == null) return {'error': 'Enter an npub or an Arca address.'};
        final amount = grainsOf(args['amount'] as String? ?? '');
        if (amount == null) return {'error': 'Enter an amount in marcas, like 12.5.'};
        final r = await _chainCmd('send', {'profile': id, 'to': to, 'amount': amount});
        return r['error'] == null ? null : r;
      case 'chainKeep':
        final r = await _chainCmd('keep', {'profile': id, 'partition': args['partition'], 'keep': args['keep']});
        return _chainSetting('keep', r['keep']);
      case 'chainMining':
        await _chainCmd('mining', {'profile': id, 'on': args['on']});
        return _chainSetting('mining', args['on']);
      case 'chainPayout':
        final r = await _chainCmd('payout', {'profile': id});
        return r['error'] == null ? null : r;
      case 'chainClaim':
        final r = await _chainCmd('claim', {'profile': id});
        return r['error'] == null ? null : r;
    }
    return {'error': 'unknown command $command'};
  }

  Future<void> _chainStop() async {
    final port = _chainPort;
    if (port == null) return;
    await _chainInbound?.cancel();
    _chainStopped = Completer<void>();
    (await port).send(['stop']);
    await _chainStopped!.future.timeout(const Duration(seconds: 10), onTimeout: () {});
  }
}
