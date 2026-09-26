// Reading passes (whitepaper, sections 8 and 9). A reader buys a 24-hour
// pass for a circle at the price its admin set; while it is active the
// reader signs, for each server, a running total of the bytes that server
// delivered. After the pass ends, each server submits its latest total
// once. When the settlement window closes the chain splits the price: half
// burned, half to the servers by bytes delivered (back to the reader if no
// server settled). The burned half counts towards the interest of the
// collection the pass names, when the reader is not a member.

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as c;

import '../crypto/hex.dart';
import '../crypto/schnorr.dart';
import 'params.dart';
import 'state.dart';
import 'tx.dart' show canonicalJson;

class PassState {
  PassState({
    required this.reader,
    required this.circle,
    required this.collection,
    required this.price,
    required this.expires,
    Map<String, int>? delivered,
  }) : delivered = delivered ?? {};

  final String reader;
  final String circle;

  /// The collection the reader came for ('' for the circle as a whole).
  final String collection;
  final int price;

  /// The tick the pass stops being valid for reading.
  final int expires;

  /// Server key to the bytes the reader signed for it.
  final Map<String, int> delivered;

  bool activeAt(int tick) => tick < expires;

  Map<String, Object?> toJson() => {
    'reader': reader,
    'circle': circle,
    'collection': collection,
    'price': price,
    'expires': expires,
    'delivered': delivered,
  };

  factory PassState.fromJson(Map m) => PassState(
    reader: m['reader'] as String,
    circle: m['circle'] as String,
    collection: m['collection'] as String,
    price: m['price'] as int,
    expires: m['expires'] as int,
    delivered: (m['delivered'] as Map).cast<String, int>(),
  );

  PassState copy() => PassState(
    reader: reader,
    circle: circle,
    collection: collection,
    price: price,
    expires: expires,
    delivered: Map.of(delivered),
  );
}

/// What a reader signs for [server] (key, hex): [bytes] delivered so far
/// under [pass].
Uint8List receiptMessage(String pass, String server, int bytes) =>
    Uint8List.fromList(c.sha256.convert(utf8.encode(canonicalJson(['arca-receipt-v1', pass, server, bytes]))).bytes);

/// A reader's signed running total, as a server keeps it and submits it.
class Receipt {
  const Receipt({required this.pass, required this.server, required this.bytes, required this.sig});

  final String pass;
  final String server;
  final int bytes;
  final String sig;

  factory Receipt.sign(List<int> readerKey, String pass, String server, int bytes) => Receipt(
    pass: pass,
    server: server,
    bytes: bytes,
    sig: toHex(schnorrSign(readerKey, receiptMessage(pass, server, bytes))),
  );

  bool verify(String reader) {
    try {
      return schnorrVerify(fromHex(reader), receiptMessage(pass, server, bytes), fromHex(sig));
    } catch (_) {
      return false;
    }
  }

  /// The body of this server's settle transaction.
  Map<String, Object?> settleBody() => {'pass': pass, 'bytes': bytes, 'sig': sig};
}

/// Closes every pass whose settlement window ended by [tick]: burns half,
/// pays the servers the other half by bytes. Called as each day starts.
void closePasses(ChainState s, int tick) {
  final done = [
    for (final e in s.passes.entries)
      if (tick >= e.value.expires + s.params.passSettleTicks) e.key,
  ]..sort();
  for (final id in done) {
    final pass = s.passes.remove(id)!;
    final burn = pass.price * ChainParams.passBurnPercent ~/ 100;
    final toServers = pass.price - burn;
    final total = pass.delivered.values.fold(0, (a, b) => a + b);
    var paid = 0;
    if (total > 0) {
      for (final server in pass.delivered.keys.toList()..sort()) {
        final share = (BigInt.from(toServers) * BigInt.from(pass.delivered[server]!) ~/ BigInt.from(total)).toInt();
        s.balances[server] = s.balanceOf(server) + share;
        paid += share;
      }
      s.burned += pass.price - paid; // the half, and what rounding left
    } else {
      s.burned += burn;
      s.balances[pass.reader] = s.balanceOf(pass.reader) + toServers; // nobody served
    }
    s.burnedFor(pass.reader, pass.collection, burn);
  }
}
