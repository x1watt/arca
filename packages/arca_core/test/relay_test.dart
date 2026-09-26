import 'dart:io';

import 'package:arca_core/src/crypto/schnorr.dart';
import 'package:arca_core/src/nostr/event.dart';
import 'package:arca_core/src/nostr/filter.dart';
import 'package:arca_core/src/relay/event_store.dart';
import 'package:arca_core/src/nostr/messages.dart';
import 'package:arca_core/src/relay/nostr_node.dart';
import 'package:arca_core/src/relay/relay.dart';
import 'package:arca_core/src/transport/link.dart';
import 'package:test/test.dart';

void main() {
  group('event store', () {
    test('keeps only the newest replaceable and addressable events', () async {
      final sk = generateSecretKey();
      final s = MemoryEventStore();
      final p1 = NostrEvent.sign(secretKey: sk, kind: 0, content: 'v1', createdAt: 10);
      final p2 = NostrEvent.sign(secretKey: sk, kind: 0, content: 'v2', createdAt: 20);
      expect(await s.add(p1), AddResult.added);
      expect(await s.add(p2), AddResult.replacedOlder);
      expect(await s.add(p1), AddResult.olderThanStored);
      final a1 = NostrEvent.sign(
        secretKey: sk,
        kind: 30078,
        content: 'a',
        createdAt: 5,
        tags: [
          ['d', 'x'],
        ],
      );
      final a2 = NostrEvent.sign(
        secretKey: sk,
        kind: 30078,
        content: 'b',
        createdAt: 5,
        tags: [
          ['d', 'y'],
        ],
      );
      await s.add(a1);
      await s.add(a2);
      expect(
        (await s.query([
          const NostrFilter(kinds: [0]),
        ])).single.content,
        'v2',
      );
      expect(
        (await s.query([
          const NostrFilter(kinds: [30078]),
        ])).length,
        2,
      );
    });

    test('an author can delete their own events, not others\'', () async {
      final alice = generateSecretKey(), bob = generateSecretKey();
      final s = MemoryEventStore();
      final a = NostrEvent.sign(secretKey: alice, kind: 1, content: 'a');
      final b = NostrEvent.sign(secretKey: bob, kind: 1, content: 'b');
      await s.add(a);
      await s.add(b);
      await s.add(
        NostrEvent.sign(
          secretKey: alice,
          kind: 5,
          content: '',
          tags: [
            ['e', a.id],
            ['e', b.id],
          ],
        ),
      );
      expect(await s.byId(a.id), isNull);
      expect(await s.byId(b.id), isNotNull);
      expect(await s.add(a), AddResult.deleted);
    });

    test('the file store survives a restart', () async {
      final dir = await Directory.systemTemp.createTemp('arca_store');
      final f = File('${dir.path}/events.jsonl');
      final sk = generateSecretKey();
      var s = await FileEventStore.open(f);
      await s.add(NostrEvent.sign(secretKey: sk, kind: 1, content: 'kept'));
      await s.add(NostrEvent.sign(secretKey: sk, kind: 0, content: 'old', createdAt: 1));
      await s.add(NostrEvent.sign(secretKey: sk, kind: 0, content: 'new', createdAt: 2));
      await s.close();
      s = await FileEventStore.open(f);
      expect(await s.count(), 2);
      expect(
        (await s.query([
          const NostrFilter(kinds: [0]),
        ])).single.content,
        'new',
      );
      await s.close();
      await dir.delete(recursive: true);
    });
  });

  group('relay', () {
    test('pushes new events to live subscriptions until they expire', () async {
      var now = DateTime(2026);
      final sent = <(String, NostrMessage)>[];
      final relay = NostrRelay(store: MemoryEventStore(), reply: (to, m) async => sent.add((to, m)), clock: () => now);
      await relay.handle(
        'peer',
        const ReqMessage('live', [
          NostrFilter(kinds: [1]),
        ]),
      );
      expect(sent.last.$2, isA<EoseMessage>());
      final e = NostrEvent.sign(secretKey: generateSecretKey(), kind: 1, content: 'fresh');
      await relay.handle('author', EventMessage(e));
      expect(sent.where((s) => s.$1 == 'peer' && s.$2 is SubscriptionEvent).length, 1);
      now = now.add(const Duration(minutes: 11));
      await relay.handle(
        'author',
        EventMessage(NostrEvent.sign(secretKey: generateSecretKey(), kind: 1, content: 'later')),
      );
      expect(sent.where((s) => s.$1 == 'peer' && s.$2 is SubscriptionEvent).length, 1, reason: 'expired');
      expect(relay.liveSubscriptions, 0);
    });
  });

  group('relay over a link', () {
    late LoopbackNetwork net;
    late NostrNode alice, owner, circleRelay;
    final aliceKey = generateSecretKey();

    setUp(() {
      net = LoopbackNetwork();
      NostrNode node(String addr) => NostrNode(address: addr, link: net.link([addr]), store: MemoryEventStore());
      alice = node('alice.b32.i2p');
      owner = node('owner.b32.i2p');
      circleRelay = node('relay.b32.i2p');
    });

    test('a comment published to the owner can be read back by anyone', () async {
      final c = NostrEvent.sign(
        secretKey: aliceKey,
        kind: Kind.comment,
        content: 'nice guide',
        tags: [
          ['I', 'arca:sha256:aa'],
        ],
      );
      final r = await alice.publish('owner.b32.i2p', c);
      expect(r.accepted, isTrue);
      final got = await circleRelay.query('owner.b32.i2p', [
        const NostrFilter(
          kinds: [Kind.comment],
          tags: {
            'I': ['arca:sha256:aa'],
          },
        ),
      ]);
      expect(got.single.id, c.id);
    });

    test('the author\'s notes stay readable from a circle relay while the author is offline', () async {
      final note = NostrEvent.sign(secretKey: aliceKey, kind: 1, content: 'hello circle');
      await alice.relay.publishLocal(note);
      expect((await alice.publish('relay.b32.i2p', note)).accepted, isTrue);
      net.setOnline('alice.b32.i2p', false);
      final got = await owner.query('relay.b32.i2p', [
        NostrFilter(authors: [note.pubkey]),
      ]);
      expect(got.single.content, 'hello circle');
    });

    test('forged events are refused with a reason', () async {
      final good = NostrEvent.sign(secretKey: aliceKey, kind: 1, content: 'x');
      final forged = NostrEvent.fromJson({...good.toJson(), 'content': 'y'});
      final r = await alice.publish('owner.b32.i2p', forged, attempts: 1);
      expect(r.accepted, isFalse);
      expect(r.message, startsWith('invalid'));
    });

    test('a moderation policy can refuse banned authors', () async {
      final banned = generateSecretKey();
      final strict = NostrNode(
        address: 'strict.b32.i2p',
        link: net.link(['strict.b32.i2p']),
        store: MemoryEventStore(),
        policy: (e, from) => e.pubkey == NostrEvent.sign(secretKey: banned, kind: 1, content: '').pubkey
            ? 'blocked: banned in this circle'
            : null,
      );
      final r = await alice.publish('strict.b32.i2p', NostrEvent.sign(secretKey: banned, kind: 1, content: 'spam'));
      expect(r.message, 'blocked: banned in this circle');
      await strict.close();
    });

    test('a finished query leaves no subscription behind, and later events show up', () async {
      await owner.query('relay.b32.i2p', [
        const NostrFilter(kinds: [1]),
      ]);
      final n = NostrEvent.sign(secretKey: aliceKey, kind: 1, content: 'late');
      await alice.publish('relay.b32.i2p', n);
      expect(circleRelay.relay.liveSubscriptions, 0, reason: 'query closes its subscription');
      final again = await owner.query('relay.b32.i2p', [
        const NostrFilter(kinds: [1]),
      ]);
      expect(again.map((e) => e.content), contains('late'));
    });

    test('publishing retries through message loss', () async {
      net.dropRate = 0.5;
      final e = NostrEvent.sign(secretKey: aliceKey, kind: 1, content: 'lossy');
      final r = await alice.publish('owner.b32.i2p', e, attempts: 8, timeout: const Duration(milliseconds: 50));
      expect(r.accepted, isTrue);
    });

    test('a relay that is not reachable yet is retried until it appears', () async {
      final late = 'late.b32.i2p';
      alice.retryDelay = const Duration(milliseconds: 20);
      net.setOnline(late, false);
      final lateNode = NostrNode(address: late, link: net.link([late]), store: MemoryEventStore());
      Future<void>.delayed(const Duration(milliseconds: 60), () => net.setOnline(late, true));
      final e = NostrEvent.sign(secretKey: aliceKey, kind: 1, content: 'hello when you arrive');
      final r = await alice.publish(late, e, attempts: 1, timeout: const Duration(seconds: 2));
      expect(r.accepted, isTrue);
      await lateNode.close();
    });

    test('an unreachable relay times out', () async {
      final e = NostrEvent.sign(secretKey: aliceKey, kind: 1, content: 'nobody home');
      final r = await alice.publish('ghost.b32.i2p', e, attempts: 2, timeout: const Duration(milliseconds: 20));
      expect(r.timedOut, isTrue);
    });
  });
}
