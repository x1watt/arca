// The device's presence on the network (docs/architecture.md, 5): one I2P
// node, and for every profile that is online its own destination with its
// own relay on it.

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:i2p/i2p.dart';

import '../nostr/event.dart';
import '../relay/event_store.dart';
import '../relay/nostr_node.dart';
import '../transport/blobs.dart';
import '../transport/i2p_link.dart';
import '../transport/link.dart';

/// What the network needs to know about a profile to put it online.
class OnlineProfile {
  const OnlineProfile({
    required this.id,
    required this.pubkey,
    required this.i2pEncSeed,
    required this.i2pSignSeed,
    required this.store,
    this.policy,
    this.resolve,
  });
  final String id;
  final String pubkey;
  final Uint8List i2pEncSeed;
  final Uint8List i2pSignSeed;
  final EventStore store;

  /// Extra rules for events from others, on top of "own events and events
  /// that tag the owner" (roles on collections).
  final Future<String?> Function(NostrEvent event)? policy;

  /// Files this profile shares, by SHA-256, for [BlobService].
  final Future<String?> Function(String sha256)? resolve;
}

enum NetState { off, starting, up, failed }

/// First byte of the probe a profile sends itself (NetworkManager).
const probeTag = 0xB0;

/// The transport under the network manager: I2P in the app, a loopback
/// network in tests.
abstract class NetworkBackend {
  /// Brings the transport up; true when it can carry messages.
  Future<bool> start();

  MessageLink get link;

  /// Starts answering for a profile's destination; returns its address.
  Future<String?> addDestination(Uint8List encSeed, Uint8List signSeed);

  Future<void> removeDestination(String address);

  /// Starts the transport afresh under the same [link] and addresses, for
  /// when it stopped carrying messages; true when it is back.
  Future<bool> restart();

  Future<void> stop();
}

/// The production backend: an i2p-dart node in its own isolate.
class I2pBackend implements NetworkBackend {
  I2pBackend(this.stateDir, {this.log});

  final String stateDir;
  final void Function(String)? log;
  I2pService? _service;
  I2pLink? _link;

  /// The seeds of the destinations added, by address, to add them again
  /// after a restart.
  final _seeds = <String, (Uint8List, Uint8List)>{};

  @override
  Future<bool> start() async {
    await Directory(stateDir).create(recursive: true);
    final idFile = File('$stateDir/identity.key');
    var identity = await idFile.exists() ? I2pIdentity.fromBytes(await idFile.readAsBytes()) : null;
    if (identity == null) {
      identity = I2pIdentity.generate();
      await idFile.writeAsBytes(identity.toBytes(), flush: true);
      if (Platform.isLinux || Platform.isMacOS) await Process.run('chmod', ['600', idFile.path]);
    }
    final s = I2pService(identity: identity, stateDir: stateDir, log: log);
    _service = s;
    if (_link == null) {
      _link = I2pLink(s);
    } else {
      _link!.use(s);
    }
    return s.ensureStarted();
  }

  @override
  Future<bool> restart() async {
    _service?.stop();
    if (!await start()) return false;
    for (final (enc, sign) in _seeds.values) {
      await _service!.addSharedDestination(enc, sign);
    }
    return true;
  }

  @override
  MessageLink get link => _link!;

  @override
  Future<String?> addDestination(Uint8List encSeed, Uint8List signSeed) async {
    final a = await _service!.addSharedDestination(encSeed, signSeed);
    if (a != null) _seeds[a] = (encSeed, signSeed);
    return a;
  }

  @override
  Future<void> removeDestination(String address) async {
    _seeds.remove(address);
    await _service?.removeSharedDestination(address);
  }

  @override
  Future<void> stop() async => _service?.stop();
}

/// A loopback backend for tests; addresses are derived from the seeds.
class LoopbackBackend implements NetworkBackend {
  LoopbackBackend(this.net, {this.startOk = true});
  final LoopbackNetwork net;
  final bool startOk;
  final _addresses = <String>[];
  late final _Multi _multi = _Multi(net, _addresses);

  @override
  Future<bool> start() async => startOk;

  @override
  MessageLink get link => _multi;

  @override
  Future<String?> addDestination(Uint8List encSeed, Uint8List signSeed) async {
    // The same address the seeds give on I2P, so Arca addresses match.
    final a = await sharedDestinationAddress(encSeed, signSeed);
    _addresses.add(a);
    _multi.attach(a);
    return a;
  }

  @override
  Future<void> removeDestination(String address) async => _addresses.remove(address);

  /// Counted, so tests can see the manager restart a deaf transport.
  int restarts = 0;

  @override
  Future<bool> restart() async {
    restarts++;
    return startOk;
  }

  @override
  Future<void> stop() async {}
}

/// Joins one loopback link per address into a single link.
class _Multi implements MessageLink {
  _Multi(this.net, this.addresses);
  final LoopbackNetwork net;
  final List<String> addresses;
  final _links = <String, MessageLink>{};
  final _controller = StreamController<Inbound>.broadcast();

  void attach(String a) {
    final l = net.link([a]);
    _links[a] = l;
    l.incoming.listen(_controller.add);
  }

  @override
  Stream<Inbound> get incoming => _controller.stream;

  @override
  Future<bool> send(String to, Uint8List bytes, {required String from}) =>
      _links[from]?.send(to, bytes, from: from) ?? Future.value(false);
}

class NetworkManager {
  NetworkManager(this.backend, {this.onChange, this.onEvent});

  final NetworkBackend backend;

  /// Called whenever the state or the set of online profiles changes.
  final void Function()? onChange;

  /// Called with each event another client stored in a profile's relay.
  final void Function(String profileId, NostrEvent event)? onEvent;

  NetState state = NetState.off;
  String? error;

  /// How often a profile sends itself a probe over the network, and how
  /// many probes in a row may go missing before the transport is started
  /// afresh. A node can stay "up" while it no longer reaches or hears
  /// anyone (docs/performance.md, 3.17); only a message sent all the way
  /// round shows it still works.
  Duration probeEvery = const Duration(minutes: 5);
  Duration probeWait = const Duration(seconds: 90);
  int probeMisses = 3;

  /// Times the transport was started afresh because probes went missing.
  int restarts = 0;

  /// Probes sent and probes that came back, and how long the last one took.
  int probesSent = 0, probesBack = 0;
  Duration? lastProbe;
  Timer? _probeTimer;
  int _missed = 0;
  bool _probing = false;
  final _rng = Random.secure();

  final _nodes = <String, NostrNode>{};
  final _blobs = <String, BlobService>{};
  final _addresses = <String, String>{};
  final _wanted = <String, OnlineProfile>{};

  /// Profile ids currently answering on the network.
  Iterable<String> get onlineIds => _nodes.keys;

  String? addressOf(String profileId) => _addresses[profileId];

  NostrNode? nodeOf(String profileId) => _nodes[profileId];

  BlobService? blobsOf(String profileId) => _blobs[profileId];

  /// Starts the transport, then puts every wanted profile online. Safe to
  /// call once; later changes go through [setOnline].
  Future<void> start() async {
    if (state == NetState.starting || state == NetState.up) return;
    state = NetState.starting;
    error = null;
    onChange?.call();
    bool ok;
    try {
      ok = await backend.start();
    } catch (e) {
      ok = false;
      error = '$e';
    }
    if (!ok) {
      state = NetState.failed;
      error ??=
          'The I2P node could not start. Check the internet connection; the first start downloads the list of routers.';
      onChange?.call();
      return;
    }
    state = NetState.up;
    for (final p in _wanted.values.toList()) {
      await _attach(p);
    }
    _probeTimer ??= Timer.periodic(probeEvery, (_) => _probe());
    onChange?.call();
  }

  /// Sends a probe from one of our addresses to itself and waits for it.
  /// After [probeMisses] misses in a row, restarts the transport.
  Future<void> _probe() async {
    if (_probing || _addresses.isEmpty) return;
    if (state == NetState.failed) return _restart();
    if (state != NetState.up) return;
    _probing = true;
    try {
      final address = _addresses.values.first;
      final nonce = Uint8List.fromList([probeTag, for (var i = 0; i < 16; i++) _rng.nextInt(256)]);
      final back = backend.link.incoming
          .where((m) => m.to == address && m.bytes.length == nonce.length && _same(m.bytes, nonce))
          .first
          .then((_) => true)
          .timeout(probeWait, onTimeout: () => false);
      final sw = Stopwatch()..start();
      probesSent++;
      final sent = await backend.link.send(address, nonce, from: address);
      final ok = sent && await back;
      if (ok) {
        probesBack++;
        lastProbe = sw.elapsed;
        _missed = 0;
        return;
      }
      _missed++;
      stderr.writeln('network: probe $_missed of $probeMisses went missing');
      if (_missed < probeMisses) return;
      _missed = 0;
      stderr.writeln('network: nothing gets through; starting the transport afresh');
      await _restart();
    } finally {
      _probing = false;
    }
  }

  /// Starts the transport afresh under the same link and addresses; tried
  /// again at the next probe if it fails.
  Future<void> _restart() async {
    restarts++;
    state = NetState.starting;
    error = null;
    onChange?.call();
    final up = await backend.restart();
    state = up ? NetState.up : NetState.failed;
    if (!up) error = 'The I2P node stopped answering and could not start again yet; Arca keeps trying.';
    onChange?.call();
  }

  static bool _same(Uint8List a, Uint8List b) {
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Puts a profile online (or keeps it online). Takes effect at once when
  /// the node is up, otherwise when it comes up.
  Future<void> setOnline(OnlineProfile p) async {
    _wanted[p.id] = p;
    if (state == NetState.up && !_nodes.containsKey(p.id)) {
      await _attach(p);
      onChange?.call();
    }
  }

  Future<void> setOffline(String profileId) async {
    _wanted.remove(profileId);
    final node = _nodes.remove(profileId);
    final address = _addresses.remove(profileId);
    await node?.close();
    await _blobs.remove(profileId)?.close();
    if (address != null) await backend.removeDestination(address);
    onChange?.call();
  }

  bool isWanted(String profileId) => _wanted.containsKey(profileId);

  Future<void> _attach(OnlineProfile p) async {
    final address = await backend.addDestination(p.i2pEncSeed, p.i2pSignSeed);
    if (address == null) return;
    _addresses[p.id] = address;
    _nodes[p.id] = NostrNode(
      address: address,
      link: backend.link,
      store: p.store,
      policy: (e, from) async => _accepts(p.pubkey, e) ?? await p.policy?.call(e),
      onStored: (e) {
        onEvent?.call(p.id, e);
        onChange?.call();
      },
    );
    _blobs[p.id] = BlobService(address: address, link: backend.link, resolve: p.resolve ?? (_) async => null);
  }

  /// Until circles and collections exist, a profile's relay keeps its own
  /// events and events addressed to it; everything else is refused.
  static String? _accepts(String owner, NostrEvent e) {
    if (e.pubkey == owner) return null;
    if (e.tagValues('p').contains(owner)) return null;
    return 'restricted: this relay only keeps events for its owner';
  }

  Future<void> stop() async {
    _probeTimer?.cancel();
    _probeTimer = null;
    for (final n in _nodes.values) {
      await n.close();
    }
    for (final b in _blobs.values) {
      await b.close();
    }
    _nodes.clear();
    _blobs.clear();
    _addresses.clear();
    await backend.stop();
    state = NetState.off;
    onChange?.call();
  }
}
