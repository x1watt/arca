import 'package:arca_core/src/crypto/hex.dart';
import 'package:arca_core/src/crypto/schnorr.dart';
import 'package:arca_core/src/nostr/event.dart';
import 'package:arca_core/src/nostr/filter.dart';
import 'package:arca_core/src/nostr/messages.dart';
import 'package:arca_core/src/nostr/nip19.dart';
import 'package:test/test.dart';

void main() {
  group('NIP-19', () {
    // Examples from the NIP-19 text.
    const npub = 'npub10elfcs4fr0l0r8af98jlmgdh9c8tcxjvz9qkw038js35mp4dma8qzvjptg';
    const pub = '7e7e9c42a91bfef19fa929e5fda1b72e0ebc1a4c1141673e2794234d86addf4e';
    const nsec = 'nsec1vl029mgpspedva04g90vltkh6fvh240zqtv9k0t9af8935ke9laqsnlfe5';
    const sec = '67dea2ed018072d675f5415ecfaed7d2597555e202d85b3d65ea4e58d2d92ffa';

    test('encodes and decodes npub and nsec', () {
      expect(npubEncode(fromHex(pub)), npub);
      expect(nsecEncode(fromHex(sec)), nsec);
      expect(toHex(decodeEntity(npub, 'npub')), pub);
      expect(toHex(decodeEntity(nsec.toUpperCase(), 'nsec')), sec);
    });

    test('rejects a wrong prefix, a bad checksum and mixed case', () {
      expect(() => decodeEntity(npub, 'nsec'), throwsFormatException);
      expect(() => decodeEntity('${npub.substring(0, npub.length - 1)}q', 'npub'), throwsFormatException);
      expect(() => decodeEntity('Npub${npub.substring(4)}', 'npub'), throwsFormatException);
    });
  });

  group('events', () {
    test('id matches an independent serialization', () {
      // Computed with Python json.dumps(separators=(",", ":"), ensure_ascii=False).
      final id = NostrEvent.computeId(
        '7e7e9c42a91bfef19fa929e5fda1b72e0ebc1a4c1141673e2794234d86addf4e',
        1700000000,
        1111,
        [
          ['I', 'arca:sha256:ab'],
          ['K', 'arca:sha256'],
        ],
        'Olá "mundo"\n\ttab',
      );
      expect(id, '1f290229f0a64cfafa1b9c836bf409d1f01b9674199ff9daaac369cbfd3e898e');
    });

    test('signed events verify, and any change breaks them', () {
      final sk = generateSecretKey();
      final e = NostrEvent.sign(
        secretKey: sk,
        kind: Kind.comment,
        content: 'hello',
        tags: [
          ['I', 'arca:sha256:00'],
        ],
      );
      expect(e.pubkey, toHex(publicKeyOf(sk)));
      expect(e.verify(), isTrue);
      final json = e.toJson();
      final back = NostrEvent.fromJson(json);
      expect(back.verify(), isTrue);
      final changed = NostrEvent.fromJson({...json, 'content': 'hellO'});
      expect(changed.verify(), isFalse);
      final otherSig = NostrEvent.fromJson({...json, 'sig': '00' * 64});
      expect(otherSig.verify(), isFalse);
    });

    test('kind classes', () {
      NostrEvent k(int kind) =>
          NostrEvent(id: '', pubkey: '', createdAt: 0, kind: kind, tags: const [], content: '', sig: '');
      expect(k(0).isReplaceable, isTrue);
      expect(k(10002).isReplaceable, isTrue);
      expect(k(1).isReplaceable, isFalse);
      expect(k(24242).isEphemeral, isTrue);
      expect(k(30078).isAddressable, isTrue);
    });
  });

  group('filters', () {
    final sk = generateSecretKey();
    final e = NostrEvent.sign(
      secretKey: sk,
      kind: 1111,
      content: 'x',
      createdAt: 100,
      tags: [
        ['I', 'arca:sha256:aa'],
      ],
    );

    test('match on authors, kinds, tags and time', () {
      expect(NostrFilter(authors: [e.pubkey]).matches(e), isTrue);
      expect(const NostrFilter(kinds: [1]).matches(e), isFalse);
      expect(
        const NostrFilter(
          tags: {
            'I': ['arca:sha256:aa'],
          },
        ).matches(e),
        isTrue,
      );
      expect(
        const NostrFilter(
          tags: {
            'I': ['arca:sha256:bb'],
          },
        ).matches(e),
        isFalse,
      );
      expect(const NostrFilter(since: 101).matches(e), isFalse);
      expect(const NostrFilter(until: 100).matches(e), isTrue);
    });

    test('round trip through JSON', () {
      const f = NostrFilter(
        kinds: [1111],
        tags: {
          'I': ['x'],
        },
        limit: 5,
      );
      final back = NostrFilter.fromJson(f.toJson());
      expect(back.kinds, [1111]);
      expect(back.tags['I'], ['x']);
      expect(back.limit, 5);
      expect(f.toJson().containsKey('authors'), isFalse);
    });
  });

  group('relay messages', () {
    test('encode and decode each type', () {
      final e = NostrEvent.sign(secretKey: generateSecretKey(), kind: 1, content: 'hi');
      for (final m in <NostrMessage>[
        EventMessage(e),
        SubscriptionEvent('s1', e),
        const ReqMessage('s1', [
          NostrFilter(kinds: [1]),
        ]),
        const CloseMessage('s1'),
        const EoseMessage('s1'),
        OkMessage(e.id, true, ''),
        const ClosedMessage('s1', 'error: gone'),
        const NoticeMessage('hello'),
      ]) {
        final back = NostrMessage.decode(m.encode());
        expect(back.runtimeType, m.runtimeType);
        expect(back.toJson().toString(), m.toJson().toString());
      }
    });

    test('rejects junk', () {
      expect(() => NostrMessage.decode('nope'.codeUnits), throwsFormatException);
      expect(() => NostrMessage.decode('["WHAT"]'.codeUnits), throwsFormatException);
      expect(() => NostrMessage.decode('["OK", 1, true, ""]'.codeUnits), throwsFormatException);
    });
  });
}
