// Files between Arca clients (docs/architecture.md, 5.7): content by
// SHA-256, in chunks small enough for one I2P datagram, on the same link
// and addresses as the Nostr messages. Binary messages start with a byte
// that can never start a Nostr message ('['), so each side ignores the
// other's traffic.
//
//   GET   0xA1 sha256[32] offset[8] length[4]
//   DATA  0xA2 sha256[32] offset[8] total[8] bytes
//   MISS  0xA3 sha256[32]
//
// Downloads write into `<target>.part`, remember which chunks arrived in
// `<target>.part.have`, continue where they stopped, and are renamed into
// place only when the whole file matches its SHA-256.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../crypto/hex.dart';
import '../library/library.dart' show hashFile;
import 'link.dart';

const _get = 0xA1, _data = 0xA2, _miss = 0xA3;

/// Bytes per chunk: with the header, one message stays under the 32 KiB
/// I2P datagram limit.
const blobChunk = 24 * 1024;

class BlobResult {
  const BlobResult({this.error, this.cancelled = false});
  final String? error;
  final bool cancelled;
  bool get ok => error == null && !cancelled;
}

class BlobService {
  BlobService({
    required this.address,
    required this.link,
    required this.resolve,
    this.window = 8,
    this.chunkTimeout = const Duration(seconds: 20),
  }) {
    _sub = link.incoming.where((m) => m.to == address && m.bytes.isNotEmpty).listen(_onInbound);
  }

  /// This profile's address.
  final String address;
  final MessageLink link;

  /// The path of the file with this SHA-256 (hex) that this profile shares,
  /// or null. Only these are served.
  final Future<String?> Function(String sha256) resolve;

  /// Requests in flight per download.
  final int window;
  final Duration chunkTimeout;

  late final StreamSubscription<Inbound> _sub;
  final _downloads = <String, _Download>{};

  /// Bytes served since start, for the transfers view.
  int served = 0;

  Future<void> close() => _sub.cancel();

  void _onInbound(Inbound m) {
    final b = m.bytes;
    if (b.length < 33) return;
    final sha = toHex(b.sublist(1, 33));
    final data = ByteData.sublistView(b);
    switch (b[0]) {
      case _get when b.length >= 45:
        unawaited(_serve(m.from, sha, data.getUint64(33), data.getUint32(41)));
      case _data when b.length >= 49:
        _downloads[sha]?.received(m.from, data.getUint64(33), data.getUint64(41), Uint8List.sublistView(b, 49));
      case _miss:
        _downloads[sha]?.missing(m.from);
    }
  }

  Future<void> _serve(String to, String sha, int offset, int length) async {
    final path = await resolve(sha);
    final header = BytesBuilder(copy: false);
    if (path == null) {
      header
        ..addByte(_miss)
        ..add(fromHex(sha));
      await link.send(to, header.takeBytes(), from: address);
      return;
    }
    RandomAccessFile? f;
    try {
      f = await File(path).open();
      final total = await f.length();
      if (offset >= total) return;
      await f.setPosition(offset);
      final bytes = await f.read(length.clamp(0, blobChunk));
      final head = ByteData(17)
        ..setUint8(0, _data)
        ..setUint64(1, offset)
        ..setUint64(9, total);
      header
        ..addByte(_data)
        ..add(fromHex(sha))
        ..add(Uint8List.sublistView(head, 1))
        ..add(bytes);
      served += bytes.length;
      await link.send(to, header.takeBytes(), from: address);
    } on FileSystemException {
      return;
    } finally {
      await f?.close();
    }
  }

  /// Fetches the file with [sha256] and [size] bytes from any of
  /// [providers] into [target]. [onProgress] gets the bytes held so far.
  Future<BlobResult> fetch(
    String sha256,
    int size,
    List<String> providers,
    String target, {
    void Function(int received)? onProgress,
    bool Function()? cancelled,
  }) async {
    if (await File(target).exists()) {
      final (have, _, _) = await hashFile(File(target));
      if (have == sha256) return const BlobResult();
    }
    final others = providers.where((p) => p != address).toSet().toList();
    if (others.isEmpty) return const BlobResult(error: 'Nobody to download it from.');
    if (_downloads.containsKey(sha256)) return const BlobResult(error: 'Already downloading.');
    final d = _Download(this, sha256, size, others, target, onProgress, cancelled);
    _downloads[sha256] = d;
    try {
      return await d.run();
    } finally {
      _downloads.remove(sha256);
    }
  }

  Future<bool> _request(String to, String sha, int offset, int length) {
    final m = ByteData(45)
      ..setUint8(0, _get)
      ..setUint64(33, offset)
      ..setUint32(41, length);
    final bytes = m.buffer.asUint8List()..setRange(1, 33, fromHex(sha));
    return link.send(to, bytes, from: address);
  }
}

class _Download {
  _Download(this.service, this.sha, this.size, this.providers, this.target, this.onProgress, this.cancelled)
    : chunks = size == 0 ? 0 : (size + blobChunk - 1) ~/ blobChunk;

  final BlobService service;
  final String sha;
  final int size;
  final List<String> providers;
  final String target;
  final void Function(int)? onProgress;
  final bool Function()? cancelled;
  final int chunks;

  late final File _part = File('$target.part');
  late final File _haveFile = File('$target.part.have');
  late Uint8List _have;
  RandomAccessFile? _out;
  final _inFlight = <int, (DateTime, String)>{};
  final _gone = <String>{};
  final _done = Completer<BlobResult>();
  var _next = 0;
  var _received = 0;
  var _unsaved = 0;
  Future<void> _writes = Future.value();

  Future<BlobResult> run() async {
    await File(target).parent.create(recursive: true);
    _have = Uint8List(chunks);
    if (await _part.exists() && await _haveFile.exists()) {
      final saved = await _haveFile.readAsBytes();
      if (saved.length == chunks) _have = saved;
    } else if (await _part.exists()) {
      await _part.delete();
    }
    _received = _have.fold(0, (n, h) => n + h) * blobChunk;
    if (_received > size) _received = size;
    _out = await _part.open(mode: FileMode.append);
    if (chunks == 0 || !_have.contains(0)) {
      _finish();
    } else {
      _fill();
    }
    final ticker = Timer.periodic(const Duration(milliseconds: 500), (_) => _tick());
    final r = await _done.future;
    ticker.cancel();
    await _writes;
    await _out?.close();
    if (!r.ok) {
      await _haveFile.writeAsBytes(_have, flush: true);
      return r;
    }
    final (got, _, length) = await hashFile(_part);
    if (got != sha || length != size) {
      await _part.delete();
      if (await _haveFile.exists()) await _haveFile.delete();
      return const BlobResult(error: 'The file that arrived does not match its fingerprint.');
    }
    await _part.rename(target);
    if (await _haveFile.exists()) await _haveFile.delete();
    return r;
  }

  String? _provider(int chunk) {
    final live = providers.where((p) => !_gone.contains(p)).toList();
    if (live.isEmpty) return null;
    return live[chunk % live.length];
  }

  void _fill() {
    while (_inFlight.length < service.window) {
      while (_next < chunks && (_have[_next] == 1 || _inFlight.containsKey(_next))) {
        _next++;
      }
      if (_next >= chunks) break;
      if (!_ask(_next, avoid: null)) return;
      _next++;
    }
  }

  bool _ask(int chunk, {required String? avoid}) {
    var to = _provider(chunk);
    if (to == null) {
      _fail('Nobody has this file right now.');
      return false;
    }
    if (to == avoid) {
      final live = providers.where((p) => !_gone.contains(p)).toList();
      if (live.length > 1) to = live[(live.indexOf(to) + 1) % live.length];
    }
    _inFlight[chunk] = (DateTime.now(), to);
    final length = chunk == chunks - 1 ? size - chunk * blobChunk : blobChunk;
    unawaited(service._request(to, sha, chunk * blobChunk, length));
    return true;
  }

  void _tick() {
    if (_done.isCompleted) return;
    if (cancelled?.call() ?? false) {
      _done.complete(const BlobResult(cancelled: true));
      return;
    }
    final now = DateTime.now();
    for (final e in _inFlight.entries.toList()) {
      if (now.difference(e.value.$1) > service.chunkTimeout) {
        _ask(e.key, avoid: e.value.$2);
      }
    }
    // Restart the scan for chunks asked of providers that turned out gone.
    _next = 0;
    _fill();
  }

  void received(String from, int offset, int total, Uint8List bytes) {
    if (_done.isCompleted || total != size || offset % blobChunk != 0) return;
    final chunk = offset ~/ blobChunk;
    if (chunk >= chunks || _have[chunk] == 1) return;
    final expected = chunk == chunks - 1 ? size - chunk * blobChunk : blobChunk;
    if (bytes.length != expected) return;
    _have[chunk] = 1;
    _inFlight.remove(chunk);
    _received += bytes.length;
    final copy = Uint8List.fromList(bytes);
    _writes = _writes.then((_) async {
      await _out!.setPosition(offset);
      await _out!.writeFrom(copy);
      if (++_unsaved >= 64) {
        _unsaved = 0;
        await _haveFile.writeAsBytes(_have);
      }
    });
    onProgress?.call(_received);
    if (cancelled?.call() ?? false) {
      _done.complete(const BlobResult(cancelled: true));
      return;
    }
    if (!_have.contains(0)) {
      _finish();
    } else {
      _fill();
    }
  }

  void missing(String from) {
    _gone.add(from);
    for (final e in _inFlight.entries.toList()) {
      if (e.value.$2 == from) _ask(e.key, avoid: from);
    }
  }

  void _fail(String why) {
    if (!_done.isCompleted) _done.complete(BlobResult(error: why));
  }

  void _finish() {
    if (!_done.isCompleted) _done.complete(const BlobResult());
  }
}
