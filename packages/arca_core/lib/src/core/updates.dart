part of 'core_service.dart';

// Updates of Arca over I2P (docs/architecture.md, 11). A release is
// announced by an event signed with the release key; devices learn it from
// each other and fetch its files by SHA-256 over I2P, from the seed and
// from any device that already has them, then serve them on. The UI shows
// what is available; installing always waits for the user's click.
//
// Who is asked: the updates meeting point (an I2P address made from the
// release key, answered by every device that holds files of the newest
// release), the people the active profile follows, and the test network's
// full nodes this device met. Each answers with the newest release it
// holds and which of its files it has.

/// Where the update work stands.
class _UpdateStatus {
  bool checking = false, downloading = false, staging = false, cancel = false;
  String? error;

  /// The I2P download failed or found nobody: offer GitHub, explained.
  bool offerGithub = false;
  int received = 0;
  String? source;
  int? lastCheck;
  InstallKind? install;
  String? staged;
}

extension _Updates on CoreService {
  /// The release this device could move to: newer than this version and
  /// with a file for it.
  (Release, ReleaseAsset)? get _updateAvailable {
    final r = _updates.release;
    if (r == null || !(r.version > _appVersion)) return null;
    final a = r.assetFor(_target);
    return a == null ? null : (r, a);
  }

  /// The address updates are asked for and answered from: the active
  /// profile's, or any online one's.
  String? get _updateFrom {
    final active = _store.active == null ? null : net.addressOf(_activeId);
    return active ?? net.onlineIds.map(net.addressOf).nonNulls.firstOrNull;
  }

  Future<void> _updatesOpen() async {
    await _updates.load();
    final (enc, sign) = updateMeetingSeeds(_releaseKey);
    _updateMeeting = await sharedDestinationAddress(enc, sign);
    // A held file of a newer release is staged again (the staging folder
    // may be gone or stale); one of this version or older is done with.
    if (_updateAvailable != null) {
      _background(_updateStage());
    } else if (await stagingDir(_appDir).exists()) {
      try {
        await stagingDir(_appDir).delete(recursive: true);
      } on FileSystemException {
        // Not ours to remove after all; left alone.
      }
    }
  }

  /// Once the network is up: listen for queries and answers, answer at
  /// the meeting point when holding files, and check soon after the start.
  void _updatesOnline() {
    if (_closing || net.state != NetState.up || _updateInbound != null) return;
    _updateInbound = net.backend.link.incoming
        .where((m) => m.bytes.isNotEmpty && (m.bytes[0] == updateQueryTag || m.bytes[0] == updateAnswerTag))
        .listen((m) => _background(_updateMessage(m)));
    if (_updates.held.isNotEmpty) _background(_updatesJoinMeeting());
    if (_updateChecks) {
      // Tunnels settle in the first minute; then every few hours.
      _updateTimers.add(Timer(const Duration(seconds: 90), () => _background(_updateCheckAuto())));
      _updateTimers.add(Timer.periodic(const Duration(hours: 4), (_) => _background(_updateCheckAuto())));
    }
  }

  Future<void> _updateCheckAuto() async {
    if (_updateMode != 'off') await _updateCheck();
  }

  Future<void> _updatesJoinMeeting() async {
    if (_updateJoined || _updates.held.isEmpty) return;
    _updateJoined = true;
    final (enc, sign) = updateMeetingSeeds(_releaseKey);
    await net.addShared(enc, sign);
  }

  Set<String> get _ownAddresses => {...net.onlineIds.map(net.addressOf).nonNulls, ?_updateMeeting};

  Future<void> _updateMessage(Inbound m) async {
    if (_ownAddresses.contains(m.from)) return;
    if (m.bytes[0] == updateQueryTag) {
      final r = _updates.release;
      final from = m.to == _updateMeeting ? _updateFrom : m.to;
      if (r == null || from == null) return;
      // One answer per asker every ten seconds: an answer is a few KB.
      final now = DateTime.now();
      final last = _updateAnswered[m.from];
      if (last != null && now.difference(last) < const Duration(seconds: 10)) return;
      if (_updateAnswered.length > 4096) _updateAnswered.clear();
      _updateAnswered[m.from] = now;
      await net.backend.link.send(m.from, encodeUpdateAnswer(r.event, _updates.held), from: from);
      return;
    }
    // Answers are taken only while a check waits for them, and a signature
    // is checked once per announcement: nobody can keep the core busy
    // verifying what it did not ask for.
    if (m.to == _updateMeeting || DateTime.now().isAfter(_updateListenUntil)) return;
    final answer = decodeUpdateAnswer(m.bytes);
    if (answer == null) return;
    if (answer.$1.id != _updates.release?.event.id) {
      if (_updateRefused.contains(answer.$1.id)) return;
      final r = Release.tryVerify(answer.$1, key: _releaseKey);
      if (r == null) {
        if (_updateRefused.length > 256) _updateRefused.clear();
        _updateRefused.add(answer.$1.id);
        return;
      }
      if (await _updates.adopt(r)) await _updateAdopted(r);
    }
    final held = _updates.release;
    for (final sha in answer.$2) {
      if (held?.assetBySha(sha) != null) (_updateProviders[sha] ??= {}).add(m.from);
    }
  }

  /// A newer release was taken: the old one's state is dropped and the
  /// announcement goes into this device's relays, for anyone who asks.
  Future<void> _updateAdopted(Release r) async {
    _updateProviders.clear();
    _upd.cancel = true;
    final fresh = _UpdateStatus()..lastCheck = _upd.lastCheck;
    _upd = fresh;
    await _publishRelease(r);
    _push();
  }

  Future<void> _publishRelease(Release r) async {
    final ids = net.onlineIds.toList();
    if (ids.isEmpty && _store.active != null) ids.add(_activeId);
    for (final id in ids) {
      final node = net.nodeOf(id);
      if (node != null) {
        await node.relay.publishLocal(r.event);
      } else {
        await (await _eventStore(id)).add(r.event);
      }
    }
  }

  /// Asks the meeting point, the people followed and the test network's
  /// peers for the newest release, collects answers for [wait], then
  /// downloads it when the setting says so.
  Future<String?> _updateCheck({Duration wait = const Duration(seconds: 30)}) async {
    if (_upd.checking) return null;
    final from = _updateFrom, meeting = _updateMeeting;
    if (from == null || meeting == null || net.state != NetState.up) {
      return 'Arca is not on I2P yet; it looks for updates by itself once it is.';
    }
    _upd
      ..checking = true
      ..error = null;
    _updateListenUntil = DateTime.now().add(wait + const Duration(seconds: 30));
    _push();
    try {
      final targets = <String>{
        if (_store.active != null)
          for (final f in (await _followStore(_activeId)).follows)
            if (f.address.isNotEmpty) f.address,
        if (_chainPort != null && _store.active != null && _chainJoined.contains(_activeId))
          ...((await _chainCmd('peers', {'profile': _activeId}))['peers'] as List? ?? const []).cast<String>(),
      }..removeAll(_ownAddresses);
      final link = net.backend.link;
      for (final t in targets.take(32)) {
        unawaited(link.send(t, updateQuery, from: from));
      }
      // Each ask at the meeting point reaches one of the devices there.
      for (var i = 0; i < 3; i++) {
        unawaited(link.send(meeting, updateQuery, from: from));
        await Future<void>.delayed(wait ~/ 3);
      }
    } finally {
      _upd
        ..checking = false
        ..lastCheck = DateTime.now().millisecondsSinceEpoch;
    }
    final av = _updateAvailable;
    if (av != null) {
      if (_updates.holds(av.$2.sha256)) {
        if (_upd.install == null) await _updateStage();
      } else if (_updateMode == 'download') {
        _background(_updateDownload());
      }
    }
    _push();
    return null;
  }

  /// Fetches the file of the available release for this device: over I2P
  /// from the devices that said they have it, or, only when the user asks,
  /// from GitHub over HTTPS. Then gets it ready to install.
  Future<void> _updateDownload({bool github = false}) async {
    final av = _updateAvailable;
    if (av == null || _upd.downloading) return;
    final (r, a) = av;
    final file = _updates.fileOf(a);
    if (!_updates.holds(a.sha256)) {
      _upd
        ..downloading = true
        ..cancel = false
        ..error = null
        ..offerGithub = false
        ..source = github ? 'github' : 'i2p'
        ..received = 0;
      _push();
      final status = _upd;
      var lastPush = DateTime.now();
      void progress(int n) {
        status.received = n;
        if (DateTime.now().difference(lastPush) > const Duration(milliseconds: 500)) {
          lastPush = DateTime.now();
          _push();
        }
      }

      String? error;
      try {
        if (github) {
          error = await httpsDownload(
            r.githubUrl(a),
            file,
            a.size,
            a.sha256,
            onProgress: progress,
            cancelled: () => status.cancel,
          );
        } else {
          final from = _updateFrom;
          final blobs = from == null
              ? null
              : net.onlineIds.where((id) => net.addressOf(id) == from).map(net.blobsOf).nonNulls.firstOrNull;
          final providers = (_updateProviders[a.sha256] ?? const <String>{}).toList();
          if (blobs == null) {
            error = 'Arca is not on I2P yet.';
          } else if (providers.isEmpty) {
            error = 'No device on I2P that has this update answered yet.';
          } else {
            final res = await blobs.fetch(
              a.sha256,
              a.size,
              providers,
              file.path,
              onProgress: progress,
              cancelled: () => status.cancel,
            );
            error = res.cancelled ? 'Download stopped.' : res.error;
          }
        }
      } finally {
        status.downloading = false;
      }
      if (!identical(status, _upd)) return; // a newer release came meanwhile
      if (error == null && !await _updates.markHeld(a)) error = 'The file did not arrive whole.';
      if (error != null) {
        _upd
          ..error = error
          ..offerGithub = !github || _upd.offerGithub;
        _push();
        return;
      }
      _background(_updatesJoinMeeting());
    }
    await _updateStage();
  }

  /// Gets a held file ready: on a desktop whose app folder can be
  /// written, checks it again and unpacks it beside the app.
  Future<void> _updateStage() async {
    final av = _updateAvailable;
    if (av == null || _upd.staging || !_updates.holds(av.$2.sha256)) return;
    final a = av.$2;
    final kind = await installKindFor(_target, _appDir);
    if (kind != InstallKind.restart) {
      _upd.install = kind;
      _push();
      return;
    }
    _upd.staging = true;
    _push();
    try {
      if (!await UpdateStore.matches(a, _updates.fileOf(a))) {
        await _updates.forget(a);
        throw ReleaseException('The downloaded file changed on disk; it was deleted. Download it again.');
      }
      _upd
        ..staged = (await stageArchive(_updates.fileOf(a), _target!.os, _appDir)).path
        ..install = InstallKind.restart;
    } on ReleaseException catch (e) {
      _upd.error = e.message;
      // Still held (it did not unpack as an Arca folder): show the file.
      if (_updates.holds(a.sha256)) _upd.install = InstallKind.folder;
    } on Exception catch (e) {
      // Unpacking failed (no tar, no space): the file is still there.
      _upd
        ..error = 'Could not prepare the update: $e'
        ..install = InstallKind.folder;
    } finally {
      _upd.staging = false;
    }
    _push();
  }

  /// The user's click: hands the APK to the system installer (through the
  /// app), restarts into the staged version, or shows the file.
  Future<Map<String, Object?>> _updateInstall() async {
    final av = _updateAvailable;
    if (av == null) return {'error': 'No newer version is ready.'};
    final (r, a) = av;
    final file = _updates.fileOf(a);
    if (!_updates.holds(a.sha256)) return {'error': 'Download the update first.'};
    switch (_upd.install) {
      case InstallKind.apk:
        if (!await UpdateStore.matches(a, file)) {
          await _updates.forget(a);
          _upd.install = null;
          return {'error': 'The downloaded file changed on disk; it was deleted. Download it again.'};
        }
        return {'apk': file.path};
      case InstallKind.restart:
        final staged = _upd.staged;
        if (staged == null || !await isReleaseBundle(Directory(staged), _target!.os)) {
          _upd.install = null;
          _background(_updateStage());
          return {'error': 'The update is being prepared again; try in a moment.'};
        }
        // Never back to an older or the same version.
        if (!(r.version > _appVersion)) return {'error': 'That is not a newer version.'};
        await startSwap(_target!.os, _appDir, Directory(staged), _updates.dir);
        await close();
        return {'restart': true};
      case InstallKind.folder:
        await _openFolder(file);
        return {'folder': file.parent.path};
      case null:
        return {'error': 'The update is not ready yet.'};
    }
  }

  Future<void> _openFolder(File file) async {
    try {
      if (Platform.isWindows) {
        await Process.start('explorer.exe', ['/select,', file.path], mode: ProcessStartMode.detached);
      } else if (Platform.isLinux) {
        await Process.start('xdg-open', [file.parent.path], mode: ProcessStartMode.detached);
      }
    } on ProcessException {
      // The UI shows the path as well.
    }
  }

  /// A seed operator's release: [path] is a release.json beside the
  /// files; with [github] (an explicit choice: a seed is an operator's
  /// machine) the announcement and missing files come from GitHub.
  Future<Map<String, Object?>> _updateImport(String? path, {bool github = false}) async {
    NostrEvent e;
    String? dir;
    try {
      if (path != null) {
        e = NostrEvent.fromJson(jsonDecode(await File(path).readAsString()));
        dir = File(path).parent.path;
      } else if (github) {
        final url = Uri.https('github.com', '/$releaseRepository/releases/latest/download/release.json');
        e = NostrEvent.fromJson(jsonDecode(await httpsText(url)));
      } else {
        return {'error': 'Give the path of a release.json, or allow GitHub.'};
      }
    } on Object catch (x) {
      return {'error': 'Could not read the release: $x'};
    }
    final Release r;
    try {
      r = Release.verify(e, key: _releaseKey);
    } on ReleaseException catch (x) {
      return {'error': 'Refused: ${x.message}'};
    }
    if (await _updates.adopt(r)) {
      await _updateAdopted(r);
    } else if (_updates.release?.event.id != r.event.id) {
      return {'error': 'A newer release is held already (${_updates.release!.version.name}).'};
    } else {
      await _publishRelease(r);
    }
    final missing = <String>[];
    for (final a in r.assets) {
      if (_updates.holds(a.sha256)) continue;
      final local = dir == null ? null : File('$dir/${a.name}');
      if (local != null && await local.exists()) {
        if (!await _updates.importFile(a, local)) missing.add('${a.name}: does not match the release');
        continue;
      }
      if (github) {
        final err = await httpsDownload(r.githubUrl(a), _updates.fileOf(a), a.size, a.sha256);
        if (err == null && await _updates.markHeld(a)) continue;
        missing.add('${a.name}: ${err ?? 'incomplete'}');
        continue;
      }
      missing.add('${a.name}: not found');
    }
    await _updatesJoinMeeting();
    _push();
    return {'version': r.version.name, 'held': _updates.held.length, 'missing': missing};
  }

  Map<String, Object?> _updateState() {
    final av = _updateAvailable;
    final r = _updates.release;
    return {
      'current': _appVersion.name,
      'build': _appVersion.build,
      'mode': _updateMode,
      'checking': _upd.checking,
      'downloading': _upd.downloading,
      'staging': _upd.staging,
      'received': _upd.received,
      'source': _upd.source,
      'error': _upd.error,
      'offerGithub': _upd.offerGithub,
      'lastCheck': _upd.lastCheck,
      'latest': r?.version.name,
      'serving': _updates.held.length,
      if (av != null)
        'available': {
          'version': av.$1.version.name,
          'build': av.$1.version.build,
          'date': av.$1.date,
          'notes': av.$1.notes,
          'name': av.$2.name,
          'size': av.$2.size,
          'sha256': av.$2.sha256,
          'github': av.$1.githubUrl(av.$2).toString(),
          'peers': _updateProviders[av.$2.sha256]?.length ?? 0,
          'held': _updates.holds(av.$2.sha256),
          'install': _upd.install?.name,
          'path': _updates.holds(av.$2.sha256) ? _updates.fileOf(av.$2).path : null,
        },
    };
  }

  Future<Map<String, Object?>?> _updateCommand(String command, Map<String, Object?> args) async {
    switch (command) {
      case 'updateCheck':
        // The UI does not wait out the answers (they come in the state);
        // tests and tools pass how long to wait.
        final wait = args['wait'] as int?;
        final check = _updateCheck(wait: Duration(milliseconds: wait ?? 30000));
        _background(check);
        final error = wait != null
            ? await check
            : await check.timeout(const Duration(milliseconds: 300), onTimeout: () => null);
        return error == null ? null : {'error': error};
      case 'updateDownload':
        if (_updateAvailable == null) return {'error': 'No newer version is known.'};
        final github = args['github'] == true;
        if (args['wait'] == true) {
          await _updateDownload(github: github);
        } else {
          _background(_updateDownload(github: github));
          await Future<void>.delayed(Duration.zero);
        }
        return null;
      case 'updateStop':
        _upd.cancel = true;
        return null;
      case 'updateMode':
        final mode = args['mode'];
        if (mode is! String || !const {'off', 'notify', 'download'}.contains(mode)) return {'error': 'Unknown setting.'};
        _updateMode = mode;
        await _saveSettings();
        if (mode == 'download' && _updateAvailable != null) _background(_updateDownload());
        return null;
      case 'updateInstall':
        return _updateInstall();
      case 'updateImport':
        return _updateImport(args['path'] as String?, github: args['github'] == true);
    }
    return {'error': 'unknown command $command'};
  }
}
