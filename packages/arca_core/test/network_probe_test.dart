// A node can stay "up" while nothing it sends arrives (docs/performance.md,
// 3.17). The network manager sends itself a probe now and then and starts
// the transport afresh when several in a row go missing.
import 'dart:typed_data';

import 'package:arca_core/arca_core.dart';
import 'package:test/test.dart';

void main() {
  Future<(NetworkManager, LoopbackBackend)> up(LoopbackNetwork net) async {
    final backend = LoopbackBackend(net);
    final m = NetworkManager(backend)
      ..probeEvery = const Duration(milliseconds: 50)
      ..probeWait = const Duration(milliseconds: 30)
      ..probeMisses = 3;
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
}
