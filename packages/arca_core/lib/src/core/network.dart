// The device's presence on the network (docs/architecture.md, 5): one I2P
// node, and for every profile that is online its own destination with its
// own relay on it.

import 'dart:async';
import 'dart:io';
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

/// The transport under the network manager: I2P in the app, a loopback
/// network in tests.
abstract class NetworkBackend {
  /// Brings the transport up; true when it can carry messages.
  Future<bool> start();

  MessageLink get link;

  /// Starts answering for a profile's destination; returns its address.
  Future<String?> addDestination(Uint8List encSeed, Uint8List signSeed);

  Future<void> removeDestination(String address);

  Future<void> stop();
}

/// The production backend: an i2p-dart node in its own isolate.
class I2pBackend implements NetworkBackend {
  I2pBackend(this.stateDir, {this.log});

  final String stateDir;
  final void Function(String)? log;
  I2pService? _service;
  I2pLink? _link;

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
    _link = I2pLink(s);
    return s.ensureStarted();
  }

  @override
  MessageLink get link => _link!;

  @override
  Future<String?> addDestination(Uint8List encSeed, Uint8List signSeed) =>
      _service!.addSharedDestination(encSeed, signSeed);

  @override
  Future<void> removeDestination(String address) async => _service?.removeSharedDestination(address);

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
    onChange?.call();
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
