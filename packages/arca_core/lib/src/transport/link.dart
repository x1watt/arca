// The seam between Arca and the network: addressed messages between
// destinations. Production uses I2P (I2pLink); tests use LoopbackNetwork.

import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

/// A message that arrived at one of our addresses.
class Inbound {
  const Inbound(this.from, this.to, this.bytes);

  /// Sender's address, authenticated by the transport.
  final String from;

  /// Which of our addresses it was sent to.
  final String to;
  final Uint8List bytes;
}

abstract class MessageLink {
  /// Messages to any address this link answers for.
  Stream<Inbound> get incoming;

  /// Sends [bytes] to [to], signed as [from] (one of our addresses). Best
  /// effort: true when the network took it, not that it arrived.
  Future<bool> send(String to, Uint8List bytes, {required String from});
}

/// An in-process network for tests: each [link] answers for its addresses,
/// and messages are delivered asynchronously, optionally dropping some.
class LoopbackNetwork {
  LoopbackNetwork({this.dropRate = 0, this.latency = Duration.zero, int seed = 1}) : _rng = Random(seed);

  /// Share of messages silently lost, like best-effort I2P delivery.
  double dropRate;

  /// Delay before a message arrives: up to this, at random, so messages
  /// can overtake each other as they do over I2P tunnels.
  Duration latency;
  final Random _rng;
  final _owners = <String, _LoopbackLink>{};
  final _offline = <String>{};

  MessageLink link(List<String> addresses) {
    final l = _LoopbackLink(this, addresses.toSet());
    for (final a in addresses) {
      _owners[a] = l;
    }
    return l;
  }

  /// Takes an address off the network (a device switched off) or back on.
  void setOnline(String address, bool online) => online ? _offline.remove(address) : _offline.add(address);

  Future<bool> _deliver(String from, String to, Uint8List bytes) async {
    final target = _owners[to];
    if (target == null || _offline.contains(to) || _offline.contains(from)) return false;
    if (dropRate > 0 && _rng.nextDouble() < dropRate) return true;
    void arrive() => target._controller.add(Inbound(from, to, bytes));
    if (latency == Duration.zero) {
      scheduleMicrotask(arrive);
    } else {
      Timer(latency * _rng.nextDouble(), arrive);
    }
    return true;
  }
}

class _LoopbackLink implements MessageLink {
  _LoopbackLink(this._net, this._addresses);
  final LoopbackNetwork _net;
  final Set<String> _addresses;
  final _controller = StreamController<Inbound>.broadcast();

  @override
  Stream<Inbound> get incoming => _controller.stream;

  @override
  Future<bool> send(String to, Uint8List bytes, {required String from}) {
    if (!_addresses.contains(from)) return Future.value(false);
    return _net._deliver(from, to, Uint8List.fromList(bytes));
  }
}
