// MessageLink over I2P: one i2p-dart node, one port for the Nostr relay
// protocol, one destination per profile (docs/architecture.md, 5).

import 'dart:async';
import 'dart:typed_data';

import 'package:i2p/i2p.dart';

import 'link.dart';

/// Port that carries NIP-01 messages between Arca clients.
const nostrPort = 4470;

class I2pLink implements MessageLink {
  I2pLink(I2pService service, {this.port = nostrPort}) {
    use(service);
  }

  final int port;
  late I2pService _service;
  StreamSubscription<Inbound>? _sub;
  final _in = StreamController<Inbound>.broadcast();

  I2pService get service => _service;

  /// Carries on over [service] (a node started afresh after the old one
  /// stopped answering), keeping every listener of [incoming].
  void use(I2pService service) {
    _sub?.cancel();
    _service = service;
    _sub = service.messages
        .where((m) => m.port == port)
        .map((m) => Inbound(_b32(m.from), m.to != null ? _b32(m.to!) : (service.b32 ?? ''), m.payload))
        .listen(_in.add);
  }

  String _b32(Uint8List hash) => '${i2pBase32(hash)}.b32.i2p';

  /// Messages on [port] to any destination the node answers for.
  @override
  Stream<Inbound> get incoming => _in.stream;

  /// Sends as [from], a destination added with `addSharedDestination`.
  @override
  Future<bool> send(String to, Uint8List bytes, {required String from}) =>
      _service.send(to, port, bytes, fromB32: from);
}
