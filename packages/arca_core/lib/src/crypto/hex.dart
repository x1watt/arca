import 'dart:typed_data';

String toHex(List<int> bytes) {
  final sb = StringBuffer();
  for (final b in bytes) {
    sb.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

/// Parses lowercase or uppercase hex; throws [FormatException] otherwise.
Uint8List fromHex(String hex) {
  if (hex.length.isOdd) throw const FormatException('odd-length hex');
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    final v = int.tryParse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    if (v == null) throw FormatException('invalid hex at ${i * 2}');
    out[i] = v;
  }
  return out;
}

bool isHex(String s, int bytes) =>
    s.length == bytes * 2 && RegExp(r'^[0-9a-fA-F]+$').hasMatch(s);
