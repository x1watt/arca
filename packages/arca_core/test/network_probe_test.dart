// A node can stay "up" while nothing it sends arrives (docs/performance.md,
// 3.17). The network manager sends itself a probe now and then and starts
// the transport afresh when several in a row go missing.
import 'dart:io' show sleep;
import 'dart:typed_data';

import 'package:arca_core/arca_core.dart';
import 'package:test/test.dart';

void main() {
  Future<(NetworkManager, LoopbackBackend)> up(LoopbackNetwork net, {bool slowProbes = false}) async {
    final backend = LoopbackBackend(net);
    final m = NetworkManager(backend)
      ..probeEvery = Duration(milliseconds: slowProbes ? 60000 : 50)
      ..probeWait = const Duration(milliseconds: 30)
      ..probeMisses = 3
      ..heartbeat = const Duration(milliseconds: 20)
      ..tunnelLife = const Duration(seconds: 2);
    await m.setOnline(
      OnlineProfile(
        id: 'p',
        pubkey: 'a' * 64,
        i2pEncSeed: Uint8List.fromList(List.filled(32, 1)),
        i2pSignSeed: Uint8List.fromList(List.filled(32, 2)),
        store: MemoryEventStore(),
      ),
    );
    await m.start();
    return (m, backend);
  }

  test('a working network is left alone', () async {
    final (m, backend) = await up(LoopbackNetwork());
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(backend.restarts, 0);
    expect(m.state, NetState.up);
    await m.stop();
  });

  test('a network that takes messages but delivers none is started afresh', () async {
    final net = LoopbackNetwork(dropRate: 1);
    final (m, backend) = await up(net);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(backend.restarts, greaterThanOrEqualTo(1));
    expect(m.restarts, backend.restarts);
    // Once messages arrive again, it settles.
    net.dropRate = 0;
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final settled = backend.restarts;
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(backend.restarts, settled);
    expect(m.state, NetState.up);
    await m.stop();
  });

  test('back from a short freeze, one missing probe is enough to start afresh', () async {
    final net = LoopbackNetwork();
    final (m, backend) = await up(net, slowProbes: true);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    sleep(const Duration(milliseconds: 300)); // the process does not run
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(backend.restarts, 0, reason: 'the probe came back: nothing to do');
    net.dropRate = 1;
    sleep(const Duration(milliseconds: 300));
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(backend.restarts, 1, reason: 'one miss after a freeze, not three');
    await m.stop();
  });

  test('back from a freeze longer than the tunnels live, it starts afresh at once', () async {
    final (m, backend) = await up(LoopbackNetwork(), slowProbes: true);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    sleep(const Duration(milliseconds: 2500));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(backend.restarts, 1);
    await m.stop();
  });
}
