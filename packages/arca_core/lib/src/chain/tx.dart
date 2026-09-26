// Transactions on the global chain (whitepaper, sections 6 to 9). Each is
// signed by the account's key (BIP-340, the profile's Nostr key), numbered
// by a per-account nonce so it cannot be replayed, and identified by the
// SHA-256 of its canonical form. Holding proofs are the exception: they
// carry nonce 0 and use none, since replaying one changes nothing (it
// counts only on its own day, once), and a proof that missed its day must
// not hold back the steward's later transactions.

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as c;

import '../crypto/hex.dart';
import '../crypto/schnorr.dart';

abstract final class TxType {
  static const transfer = 'transfer';
  static const createCircle = 'createCircle';
  static const anchor = 'anchor';
  static const declare = 'declare';
  static const undeclare = 'undeclare';
  static const holdingProof = 'holdingProof';

  /// Whether transactions of [type] use the account's nonce.
  static bool numbered(String type) => type != holdingProof;
  static const claim = 'claim';
  static const buyPass = 'buyPass';
  static const settlePass = 'settlePass';
}

/// JSON with keys sorted at every level, so every node hashes the same bytes.
String canonicalJson(Object? v) => jsonEncode(_sorted(v));

Object? _sorted(Object? v) => switch (v) {
  final Map m => {for (final k in (m.keys.map((k) => k.toString()).toList()..sort())) k: _sorted(m[k])},
  final List l => [for (final x in l) _sorted(x)],
  _ => v,
};

class Tx {
  const Tx({required this.type, required this.from, required this.nonce, required this.body, required this.sig});

  final String type;

  /// Account (x-only public key, hex).
  final String from;
  final int nonce;
  final Map<String, Object?> body;
  final String sig;

  static Uint8List _idBytes(String type, String from, int nonce, Map<String, Object?> body) =>
      Uint8List.fromList(c.sha256.convert(utf8.encode(canonicalJson(['arca-tx-v1', type, from, nonce, body]))).bytes);

  String get id => toHex(_idBytes(type, from, nonce, body));

  factory Tx.sign(List<int> secretKey, String type, int nonce, Map<String, Object?> body) {
    final from = toHex(publicKeyOf(secretKey));
    final sig = toHex(schnorrSign(secretKey, _idBytes(type, from, nonce, body)));
    return Tx(type: type, from: from, nonce: nonce, body: body, sig: sig);
  }

  bool verify() {
    try {
      return schnorrVerify(fromHex(from), _idBytes(type, from, nonce, body), fromHex(sig));
    } catch (_) {
      return false;
    }
  }

  Map<String, Object?> toJson() => {'type': type, 'from': from, 'nonce': nonce, 'body': body, 'sig': sig};

  factory Tx.fromJson(Map m) => Tx(
    type: m['type'] as String,
    from: m['from'] as String,
    nonce: m['nonce'] as int,
    body: (m['body'] as Map).cast<String, Object?>(),
    sig: m['sig'] as String,
  );
}
