// Nostr events (NIP-01): canonical serialization, id, signing, verification.

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as c;

import '../crypto/hex.dart';
import '../crypto/schnorr.dart';

/// Event kinds Arca uses (see docs/architecture.md, 4.1).
abstract final class Kind {
  static const profile = 0;
  static const note = 1;
  static const follows = 3;
  static const deletion = 5;
  static const reaction = 7;
  static const externalReaction = 17;
  static const comment = 1111;
  static const muteList = 10000;
  static const relayList = 10002;
  static const blossomServers = 10063;
  static const blossomAuth = 24242;
  static const appData = 30078;

  /// Arca collection head (provisional number until the protocol is fixed):
  /// an addressable event keyed by the collection id.
  static const arcaCollection = 30780;
}

class NostrEvent {
  const NostrEvent({
    required this.id,
    required this.pubkey,
    required this.createdAt,
    required this.kind,
    required this.tags,
    required this.content,
    required this.sig,
  });

  /// Lowercase hex, 32 bytes.
  final String id;
  final String pubkey;

  /// Unix seconds.
  final int createdAt;
  final int kind;
  final List<List<String>> tags;
  final String content;

  /// Lowercase hex, 64 bytes.
  final String sig;

  /// Builds, hashes and signs an event with [secretKey].
  factory NostrEvent.sign({
    required List<int> secretKey,
    required int kind,
    required String content,
    List<List<String>> tags = const [],
    int? createdAt,
  }) {
    final pubkey = toHex(publicKeyOf(secretKey));
    final at = createdAt ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final id = computeId(pubkey, at, kind, tags, content);
    final sig = toHex(schnorrSign(secretKey, fromHex(id)));
    return NostrEvent(
      id: id,
      pubkey: pubkey,
      createdAt: at,
      kind: kind,
      tags: tags,
      content: content,
      sig: sig,
    );
  }

  /// The NIP-01 id: SHA-256 of `[0, pubkey, created_at, kind, tags, content]`.
  static String computeId(
    String pubkey,
    int createdAt,
    int kind,
    List<List<String>> tags,
    String content,
  ) {
    final serialized = jsonEncode([0, pubkey, createdAt, kind, tags, content]);
    return c.sha256.convert(utf8.encode(serialized)).toString();
  }

  /// True when the id matches the content and the signature is valid.
  bool verify() {
    if (!isHex(id, 32) || !isHex(pubkey, 32) || !isHex(sig, 64)) return false;
    if (computeId(pubkey, createdAt, kind, tags, content) != id) return false;
    return schnorrVerify(fromHex(pubkey), fromHex(id), fromHex(sig));
  }

  /// Values of tags named [name], for example all `e` or `I` tags.
  Iterable<String> tagValues(String name) =>
      tags.where((t) => t.length > 1 && t[0] == name).map((t) => t[1]);

  /// Replaceable (NIP-01): kinds 0, 3 and 10000 to 19999.
  bool get isReplaceable => kind == 0 || kind == 3 || (kind >= 10000 && kind < 20000);

  /// Ephemeral (NIP-01): kinds 20000 to 29999, never stored.
  bool get isEphemeral => kind >= 20000 && kind < 30000;

  /// Addressable (NIP-01): kinds 30000 to 39999, keyed by the `d` tag.
  bool get isAddressable => kind >= 30000 && kind < 40000;

  String get dTag => tagValues('d').firstOrNull ?? '';

  Map<String, Object> toJson() => {
    'id': id,
    'pubkey': pubkey,
    'created_at': createdAt,
    'kind': kind,
    'tags': tags,
    'content': content,
    'sig': sig,
  };

  /// Parses an event object; throws [FormatException] when a field is
  /// missing or of the wrong type. Does not verify.
  factory NostrEvent.fromJson(Object? json) {
    if (json is! Map) throw const FormatException('event must be an object');
    try {
      return NostrEvent(
        id: json['id'] as String,
        pubkey: json['pubkey'] as String,
        createdAt: json['created_at'] as int,
        kind: json['kind'] as int,
        tags: [
          for (final t in json['tags'] as List) [for (final v in t as List) v as String],
        ],
        content: json['content'] as String,
        sig: json['sig'] as String,
      );
    } on TypeError {
      throw const FormatException('event field of the wrong type');
    }
  }

  Uint8List get idBytes => fromHex(id);
}
