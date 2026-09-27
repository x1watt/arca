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
          _applyServing(m[1] as String);
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
    final port = await ready.future;
    port.send([
      'cmd',
      -1,
      'power',
      {..._power, ..._sharing},
    ]);
    return port;
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
      // Shown on the wallet's waiting page, and tried again in a minute (no
      // node of the network may be online yet).
      _chainJoined.remove(id);
      _chainErrors[id] = '$e';
      stderr.writeln('chain: could not start for $id: $e');
      _push();
      Timer(const Duration(minutes: 1), () {
        if (!_closing && _chainErrors.containsKey(id)) unawaited(_chainResume(id));
      });
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
    final spec = TestnetSpec((config['spec'] as Map).cast<String, Object?>());
    final p = _store.profiles.firstWhere((x) => x.id == id);
    // Phones follow lightly unless told to keep files; the founder keeps
    // the circle's log, so it is never light.
    final light = spec.founder != p.pubkey && (config['light'] as bool? ?? _isPhone);
    // The network's meeting point: newcomers ask there, and full nodes
    // answer for it once they have joined. A node that answered before it
    // had met anyone could hide the others there (its lease set replaces
    // theirs until they merge) and would only hear its own hello.
    final (enc, sign) = spec.rendezvousSeeds;
    final rendezvous = await sharedDestinationAddress(enc, sign);
    await _chainForward();
    final joined = await _chainCmd('join', {
      'profile': id,
      'pubkey': p.pubkey,
      'address': address,
      'arcaAddress': arcaAddress(p.npub, address),
      'dir': _chainConfigFile(id).parent.path,
      'spec': spec.json,
      'keep': config['keep'],
      'mining': config['mining'] ?? true,
      'keepCircle': config['keepCircle'],
      'light': light,
      'rendezvous': rendezvous,
      'peers': const <String>[],
      'files': await _chainFiles(id, spec),
    });
    if (joined['error'] != null) throw StateError(joined['error'] as String);
    if (!light) {
      _chainAddresses.add(await net.addShared(enc, sign));
      _background(_chainWatchFiles(id, spec));
    }
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
      final folder = _chainCorpusFolder(spec);
      for (final e in spec.fileNames.entries) {
        final path = '$folder/${e.value}';
        if (await File(path).exists()) out[e.key] = path;
      }
    }
    return out;
  }

  /// Where a device that keeps the test network's files holds its copy of
  /// the corpus: a folder under the default storage folder, served to
  /// others like any shared file.
  String _chainCorpusFolder(TestnetSpec spec) => '$_defaultFolder/${spec.corpusName} (test network)';

  /// Until every corpus file is here, fetches the missing ones by hash from
  /// the full nodes the worker found and tells the worker what arrived.
  Future<void> _chainWatchFiles(String id, TestnetSpec spec) async {
    var sent = -1;
    final folder = _chainCorpusFolder(spec);
    final sizes = {for (final (sha, size) in spec.files) sha: size};
    while (!_closing && _chainJoined.contains(id)) {
      final files = await _chainFiles(id, spec);
      if (files.length != sent) {
        sent = files.length;
        _shaPaths.remove(id); // served from here too now
        await _chainCmd('files', {'profile': id, 'files': files});
      }
      if (files.length == spec.files.length) return;
      final peers = ((await _chainCmd('peers', {'profile': id}))['peers'] as List? ?? const []).cast<String>();
      final blobs = net.blobsOf(id);
      if (peers.isEmpty || blobs == null) {
        await Future<void>.delayed(const Duration(seconds: 10));
        continue;
      }
      await Directory(folder).create(recursive: true);
      for (final e in spec.fileNames.entries) {
        if (_closing || files.containsKey(e.key)) continue;
        await blobs.fetch(e.key, sizes[e.key]!, peers, '$folder/${e.value}', reader: await _readerSession(id));
      }
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

  /// Takes part in the test network built into Arca (or [spec], in tests
  /// and tools). Nothing is passed by hand: the node finds the others at
  /// the network's meeting point, and a device that keeps files fetches
  /// them by hash from the peers it found.
  Future<Map<String, Object?>?> _chainJoin({bool? light, Map<String, Object?>? spec}) async {
    final id = _activeId;
    if (await _chainConfig(id) != null) return {'error': 'This profile already takes part in the test network.'};
    final s = spec != null ? TestnetSpec(spec) : TestnetSpec.builtIn;
    if (s == null) return {'error': 'This version of Arca has no test network built in.'};
    await _saveChainConfig(id, {
      'spec': s.json,
      'light': light ?? _isPhone,
      'keep': [for (var i = 0; i < s.partitionSizes.length; i++) i],
      'mining': true,
    });
    _chainNone.remove(id);
    // Right after Arca starts, I2P can take a few minutes to come up; the
    // chain starts by itself once it is.
    if (net.addressOf(id) != null) await _chainResume(id);
    return _chainErrors[id] == null ? null : {'error': _chainErrors[id]};
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

  static bool get _isPhone => Platform.isAndroid || Platform.isIOS;

  /// The circle's reading rules for what this profile serves (whitepaper,
  /// section 9): members first and free, pass holders while their receipts
  /// keep up, others within the free allowance. Without a testnet, everyone
  /// is served.
  void _applyServing(String id) {
    final blobs = net.blobsOf(id);
    if (blobs == null) return;
    final reading = _chainStates[id]?['reading'] as Map?;
    if (reading == null) {
      blobs.rules = null;
      return;
    }
    final allowance = reading['freeAllowance'] as int;
    final members = {...(reading['members'] as List).cast<String>()};
    final passes = (reading['passes'] as Map).cast<String, String>();
    blobs.rules = ServingRules(
      serverKey: _pubkeyOf(id),
      freeAllowance: allowance,
      // The owner's share of a day's upload for free readers (Settings).
      freeTotal: (_sharing['uploadLimit'] as int) * 86400 * (_sharing['freeShare'] as num).toInt() ~/ 100,
      passValid: (reader, pass) async => passes[pass] == reader,
      isMember: members.contains,
    );
    // Passes that ended: settle what their readers signed for us.
    final ended = [...(reading['ended'] as List? ?? const []).cast<String>()];
    final receipts = {
      for (final p in ended)
        if (blobs.receipts[p] case final r?) p: {'bytes': r.bytes, 'sig': r.sig},
    };
    if (receipts.isNotEmpty && _settling.add(id)) {
      _background(_chainCmd('settle', {'profile': id, 'receipts': receipts}).whenComplete(() => _settling.remove(id)));
    }
  }

  /// Who this profile is when it reads from others: its key and, when it
  /// holds one, its pass, kept across downloads for the running totals.
  Future<ReaderSession?> _readerSession(String id) async {
    // Off a testnet, servers have no rules to introduce ourselves to.
    if (_chainStates[id] == null) return null;
    final pass = ((_chainStates[id]?['reading'] as Map?)?['myPass'] as Map?)?['id'] as String?;
    final known = _readers[id];
    if (known != null && known.pass == pass) return known;
    return _readers[id] = ReaderSession(await _secretKey(id), pass: pass);
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
        return _chainJoin(light: args['light'] as bool?, spec: (args['spec'] as Map?)?.cast<String, Object?>());
      case 'chainLeave':
        return _chainLeave();
      case 'chainSpec':
        // The spec of the network this profile takes part in (the seed node
        // writes it out to be built into the app).
        final config = await _chainConfig(id);
        return config == null ? {'error': 'This profile takes part in no test network.'} : {'spec': config['spec']};
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
      case 'chainReading':
        final r = await _chainCmd('reading', {
          'profile': id,
          'circle': ?args['circle'],
          'reading': {
            if (args['passPrice'] != null) 'passPrice': grainsOf('${args['passPrice']}'),
            if (args['freeAllowance'] != null) 'freeAllowance': args['freeAllowance'],
            if (args['memberScore'] != null) 'memberScore': args['memberScore'],
          },
        });
        return r['error'] == null ? null : r;
      case 'chainBuyPass':
        final r = await _chainCmd('buyPass', {'profile': id, 'circle': ?args['circle']});
        return r['error'] == null ? null : r;
      case 'chainLight':
        final config = await _chainConfig(id);
        if (config == null) return {'error': 'This profile takes part in no testnet.'};
        final spec = TestnetSpec((config['spec'] as Map).cast<String, Object?>());
        if (spec.founder == _pubkeyOf(id)) return {'error': 'The founder\'s device always keeps the files.'};
        // Keeping files fetches the corpus from the peers once it runs.
        config['light'] = args['on'] == true;
        await _saveChainConfig(id, config);
        // Restart this profile's part of the chain in the other mode.
        if (_chainJoined.remove(id)) await _chainCmd('leave', {'profile': id});
        _chainStates.remove(id);
        await _chainResume(id);
        return null;
      case 'chainPower':
        _power = {'charging': args['charging'] ?? true, 'unmetered': args['unmetered'] ?? true};
        _applySharing();
        if (_chainPort != null) await _chainCmd('power', _chainPower);
        return null;
      case 'chainPayout':
        final r = await _chainCmd('payout', {'profile': id, 'circle': ?args['circle']});
        return r['error'] == null ? null : r;
      case 'chainClaim':
        final r = await _chainCmd('claim', {'profile': id, 'circle': ?args['circle']});
        return r['error'] == null ? null : r;
      case 'chainCreateCircle':
        final r = await _chainCmd('createCircle', {'profile': id, 'circle': args['circle'], 'name': args['name']});
        return r['error'] == null ? null : r;
      case 'chainKeepFor':
        final r = await _chainCmd('keepFor', {'profile': id, 'circle': args['circle']});
        if (r['error'] != null) return r;
        return _chainSetting('keepCircle', args['circle']);
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
