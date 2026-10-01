// The explicit fallback for updates (docs/architecture.md, 11): the same
// file from the GitHub release over HTTPS, when no device on I2P has it.
// Only ever started by the user's click (or a seed operator's flag), since
// it shows GitHub this IP address; it carries no profile key or address.
// The file is checked against the SHA-256 of the signed announcement, so
// GitHub cannot change it either.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as c;

/// Downloads [url] into [target] (through `<target>.https.part`, continued
/// where it stopped) and keeps it only when it has [size] bytes and the
/// SHA-256 [sha256]. Returns null, or why it failed.
Future<String?> httpsDownload(
  Uri url,
  File target,
  int size,
  String sha256, {
  void Function(int received)? onProgress,
  bool Function()? cancelled,
  HttpClient? client,
}) async {
  final http = client ?? HttpClient();
  final part = File('${target.path}.https.part');
  await target.parent.create(recursive: true);
  var have = await part.exists() ? await part.length() : 0;
  if (have >= size) {
    await part.delete();
    have = 0;
  }
  try {
    final req = await http.getUrl(url);
    if (have > 0) req.headers.set(HttpHeaders.rangeHeader, 'bytes=$have-');
    final res = await req.close();
    if (res.statusCode == 200) {
      have = 0;
    } else if (res.statusCode != 206) {
      await res.drain<void>();
      return 'The download failed (HTTP ${res.statusCode}).';
    }
    final digest = _Digest();
    final hash = c.sha256.startChunkedConversion(digest);
    if (have > 0) {
      await for (final chunk in part.openRead()) {
        hash.add(chunk);
      }
    }
    final sink = part.openWrite(mode: have > 0 ? FileMode.append : FileMode.write);
    var got = have;
    var reported = 0;
    try {
      await for (final chunk in res) {
        if (cancelled?.call() ?? false) return 'Download stopped.';
        sink.add(chunk);
        hash.add(chunk);
        got += chunk.length;
        if (got > size) break;
        if (got - reported >= 1 << 20) {
          reported = got;
          onProgress?.call(got);
        }
      }
    } finally {
      await sink.close();
    }
    hash.close();
    if (got != size || digest.value.toString() != sha256) {
      await part.delete();
      return 'The file from GitHub did not match the signed release; it was discarded.';
    }
    await part.rename(target.path);
    onProgress?.call(got);
    return null;
  } on SocketException catch (e) {
    return 'No connection to GitHub (${e.message}).';
  } on HttpException catch (e) {
    return 'The download was interrupted (${e.message}); it continues where it stopped.';
  } on TlsException catch (e) {
    return 'The secure connection to GitHub failed (${e.message}).';
  } finally {
    if (client == null) http.close();
  }
}

/// Fetches a small text file over HTTPS (a seed's release.json), at most
/// [limit] bytes.
Future<String> httpsText(Uri url, {int limit = 1 << 20}) async {
  final http = HttpClient();
  try {
    final res = await (await http.getUrl(url)).close();
    if (res.statusCode != 200) {
      await res.drain<void>();
      throw HttpException('HTTP ${res.statusCode}', uri: url);
    }
    final bytes = <int>[];
    await for (final chunk in res) {
      bytes.addAll(chunk);
      if (bytes.length > limit) throw HttpException('too large', uri: url);
    }
    return utf8.decode(bytes);
  } finally {
    http.close();
  }
}

class _Digest implements Sink<c.Digest> {
  late c.Digest value;
  @override
  void add(c.Digest data) => value = data;
  @override
  void close() {}
}
