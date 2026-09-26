// Chain messages on the link: a 0xC1 byte, then JSON. A message bigger
// than one I2P datagram (a fraud proof carrying whole namespaces, a page
// of a snapshot) travels as numbered parts and is put back together here.

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as c;

import '../transport/link.dart';

const chainTag = 0xC1;

/// Characters of JSON per part, under the 32 KiB datagram limit.
const partChars = 20000;

Uint8List encodeChainMessage(Map<String, Object?> m) {
  final body = utf8.encode(jsonEncode(m));
  return Uint8List(body.length + 1)
    ..[0] = chainTag
    ..setRange(1, body.length + 1, body);
}

class Reassembly {
  final _pending = <String, List<String?>>{};

  /// [m] as one or more messages that each fit a datagram.
  static List<Map<String, Object?>> split(Map<String, Object?> m) {
    final text = jsonEncode(m);
    if (text.length <= partChars) return [m];
    final id = c.sha256.convert(utf8.encode(text)).toString().substring(0, 16);
    final n = (text.length + partChars - 1) ~/ partChars;
    return [
      for (var i = 0; i < n; i++)
        {
          't': 'part',
          'id': id,
          'i': i,
          'n': n,
          'd': text.substring(i * partChars, (i + 1) * partChars > text.length ? text.length : (i + 1) * partChars),
        },
    ];
  }

  /// The message [m] carries, once whole; null while parts are missing or
  /// when it is not a chain message.
  Map? add(Inbound m) {
    if (m.bytes.isEmpty || m.bytes[0] != chainTag) return null;
    final Map msg;
    try {
      msg = jsonDecode(utf8.decode(Uint8List.sublistView(m.bytes, 1))) as Map;
    } catch (_) {
      return null;
    }
    if (msg['t'] != 'part') return msg;
    final id = '${m.from}/${msg['id']}';
    final n = msg['n'] as int? ?? 0, i = msg['i'] as int? ?? -1;
    if (n < 1 || n > 512 || i < 0 || i >= n) return null;
    final parts = _pending.putIfAbsent(id, () => List<String?>.filled(n, null));
    if (parts.length != n) return null;
    parts[i] = msg['d'] as String?;
    if (parts.contains(null)) {
      if (_pending.length > 64) _pending.remove(_pending.keys.first);
      return null;
    }
    _pending.remove(id);
    try {
      return jsonDecode(parts.join()) as Map;
    } catch (_) {
      return null;
    }
  }
}
