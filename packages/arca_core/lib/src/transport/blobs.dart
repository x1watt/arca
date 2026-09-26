// Files between Arca clients (docs/architecture.md, 5.7): content by
// SHA-256, in chunks small enough for one I2P datagram, on the same link
// and addresses as the Nostr messages. Binary messages start with a byte
// that can never start a Nostr message ('['), so each side ignores the
// other's traffic.
//
//   GET     0xA1 sha256[32] offset[8] length[4]
//   DATA    0xA2 sha256[32] offset[8] total[8] bytes
//   MISS    0xA3 sha256[32]
//   HELLO   0xA4 key[32] pass[32] sig[64]        reader: who I am
//   RECEIPT 0xA5 pass[32] bytes[8] sig[64]       reader: running total
//   WELCOME 0xA6 key[32] status[1] allowance[8]  server: who I am, how I
//                                                treat you
//   LIMIT   0xA7 sha256[32] reason[1]            server: no more for now
//
// A server with [ServingRules] serves members first, then pass holders as
// long as their receipts keep up, then free readers within their daily
// allowance (see reading.dart). Without rules it serves everyone.
//
// Downloads write into `<target>.part`, remember which chunks arrived in
// `<target>.part.have`, continue where they stopped, and are renamed into
// place only when the whole file matches its SHA-256.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../chain/passes.dart' show Receipt;
import '../crypto/hex.dart';
import '../crypto/schnorr.dart';
import '../library/library.dart' show hashFile;
import 'link.dart';
import 'reading.dart';

const _get = 0xA1, _data = 0xA2, _miss = 0xA3, _hello = 0xA4, _receipt = 0xA5, _welcome = 0xA6, _limit = 0xA7;
final _noPass = Uint8List(32);

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
    this.rules,
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

  /// Who may read how much; null serves everyone.
  ServingRules? rules;

  /// While true, this device answers no requests (the owner's sharing
  /// limits: only on Wi-Fi, only while charging); readers go elsewhere.
  bool paused = false;

  /// Upload bytes per second, 0 for no limit.
  int uploadLimit = 0;
  DateTime _nextSend = DateTime.fromMillisecondsSinceEpoch(0);

  /// The latest receipt of each pass this server delivered under, to
  /// settle on the chain after the pass ends.
  final receipts = <String, Receipt>{};

  final _readers = <String, _Reader>{};
  final _freeByKey = <String, int>{};
  var _freeToday = 0;
  var _today = -1;
  final _queue = <(int, String, String, int, int)>[]; // (class, to, sha, offset, length)
  var _serving = 0;

  /// Welcomes from servers, for readers' sessions.
  final _welcomes = StreamController<String>.broadcast();
  final _serverInfo = <String, (String, ReaderStatus)>{};

  Future<void> close() async {
    await _sub.cancel();
    await _welcomes.close();
  }

  void _onInbound(Inbound m) {
    final b = m.bytes;
    if (b.length < 33) return;
    final sha = toHex(b.sublist(1, 33));
    final data = ByteData.sublistView(b);
    switch (b[0]) {
      case _get when b.length >= 45:
        _requested(m.from, sha, data.getUint64(33), data.getUint32(41));
      case _data when b.length >= 49:
        _downloads[sha]?.received(m.from, data.getUint64(33), data.getUint64(41), Uint8List.sublistView(b, 49));
      case _miss:
        _downloads[sha]?.missing(m.from);
      case _limit when b.length >= 34:
        _downloads[sha]?.limited(m.from, LimitReason.values[b[33].clamp(0, LimitReason.values.length - 1)]);
      case _hello when b.length >= 129:
        unawaited(_onHello(m.from, sha, toHex(b.sublist(33, 65)), b.sublist(65, 129)));
      case _receipt when b.length >= 105:
        _onReceipt(m.from, sha, data.getUint64(33), toHex(b.sublist(41, 105)));
      case _welcome when b.length >= 42:
        _serverInfo[m.from] = (sha, ReaderStatus.values[b[33].clamp(0, ReaderStatus.values.length - 1)]);
        _welcomes.add(m.from);
    }
  }

  // ---- Serving under rules ----

  Future<void> _onHello(String from, String key, String pass, List<int> sig) async {
    final r = rules;
    if (r == null) return;
    final hasPass = pass != toHex(_noPass);
    bool signed;
    try {
      signed = schnorrVerify(fromHex(key), helloMessage(from, address, key, hasPass ? pass : ''), sig);
    } catch (_) {
      signed = false;
    }
    if (!signed) return;
    final status = r.isMember(key)
        ? ReaderStatus.member
        : hasPass && await r.passValid(key, pass)
        ? ReaderStatus.pass
        : ReaderStatus.free;
    _readers[from] = _Reader(key, status == ReaderStatus.pass ? pass : null, status);
    _newDay();
    final left = (r.freeAllowance - (_freeByKey[key] ?? 0)).clamp(0, r.freeAllowance);
    final msg = ByteData(42)
      ..setUint8(0, _welcome)
      ..setUint8(33, status.index)
      ..setUint64(34, left);
    final bytes = msg.buffer.asUint8List()..setRange(1, 33, fromHex(r.serverKey));
    await link.send(from, bytes, from: address);
  }

  void _onReceipt(String from, String pass, int bytes, String sig) {
    final r = rules, reader = _readers[from];
    if (r == null || reader == null || reader.pass != pass || bytes <= reader.receipted) return;
    final receipt = Receipt(pass: pass, server: r.serverKey, bytes: bytes, sig: sig);
    if (!receipt.verify(reader.key)) return;
    reader.receipted = bytes;
    receipts[pass] = receipt;
  }

  void _newDay() {
    final day = DateTime.now().toUtc().millisecondsSinceEpoch ~/ Duration.millisecondsPerDay;
    if (day == _today) return;
    _today = day;
    _freeToday = 0;
    _freeByKey.clear();
  }

  void _requested(String from, String sha, int offset, int length) {
    if (paused) {
      final msg = Uint8List(33)..[0] = _miss;
      msg.setRange(1, 33, fromHex(sha));
      unawaited(link.send(from, msg, from: address));
      return;
    }
    final r = rules;
    if (r == null) {
      unawaited(_serve(from, sha, offset, length));
      return;
    }
    final status = _readers[from]?.status ?? ReaderStatus.free;
    _queue.add((2 - status.index, from, sha, offset, length));
    _pump();
  }

  void _pump() {
    final r = rules!;
    while (_serving < r.slots && _queue.isNotEmpty) {
      var best = 0;
      for (var i = 1; i < _queue.length; i++) {
        if (_queue[i].$1 < _queue[best].$1) best = i;
      }
      final (_, to, sha, offset, length) = _queue.removeAt(best);
      final refused = _admit(r, to, length.clamp(0, blobChunk));
      if (refused != null) {
        final msg = Uint8List(34)..[0] = _limit;
        msg.setRange(1, 33, fromHex(sha));
        msg[33] = refused.index;
        unawaited(link.send(to, msg, from: address));
        continue;
      }
      _serving++;
      unawaited(
        _serve(to, sha, offset, length).whenComplete(() {
          _serving--;
          _pump();
        }),
      );
    }
  }

  /// Null when [to] may have [length] more bytes now, or why not.
  LimitReason? _admit(ServingRules r, String to, int length) {
    final reader = _readers[to];
    switch (reader?.status) {
      case ReaderStatus.member:
        return null;
      case ReaderStatus.pass:
        // Lost chunks are sent again but counted once by the reader, so a
        // quarter of what was served is allowed on top of the slack.
        if (reader!.served - reader.receipted > r.receiptSlack + reader.served ~/ 4) return LimitReason.receipts;
        reader.served += length;
        return null;
      case ReaderStatus.free || null:
        _newDay();
        final key = reader?.key ?? to; // no hello: the address stands for the key
        if ((_freeByKey[key] ?? 0) + length > r.freeAllowance) return LimitReason.allowance;
        if (_freeToday + length > r.freeTotal) return LimitReason.freeShare;
        _freeByKey[key] = (_freeByKey[key] ?? 0) + length;
        _freeToday += length;
        return null;
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
      if (uploadLimit > 0) {
        // Pace chunks so the upload stays under the owner's limit.
        final now = DateTime.now();
        final start = _nextSend.isAfter(now) ? _nextSend : now;
        _nextSend = start.add(Duration(microseconds: bytes.length * 1000000 ~/ uploadLimit));
        if (start.isAfter(now)) await Future<void>.delayed(start.difference(now));
      }
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
    ReaderSession? reader,
  }) async {
    if (await File(target).exists()) {
      final (have, _, _) = await hashFile(File(target));
      if (have == sha256) return const BlobResult();
    }
    final others = providers.where((p) => p != address).toSet().toList();
    if (others.isEmpty) return const BlobResult(error: 'Nobody to download it from.');
    if (_downloads.containsKey(sha256)) return const BlobResult(error: 'Already downloading.');
    final d = _Download(this, sha256, size, others, target, onProgress, cancelled, reader);
    _downloads[sha256] = d;
    try {
      return await d.run();
    } finally {
      _downloads.remove(sha256);
    }
  }

  /// Introduces [session] to [servers] and waits (a few seconds at most)
  /// for their welcomes, so the first requests already count as its own.
  Future<void> _introduce(ReaderSession session, List<String> servers) async {
    final pending = servers.where((s) => !session.status.containsKey(s)).toSet();
    if (pending.isEmpty) return;
    final key = toHex(publicKeyOf(session.secretKey));
    final pass = session.pass ?? '';
    final done = Completer<void>();
    final sub = _welcomes.stream.listen((from) {
      final info = _serverInfo[from];
      if (info == null || !pending.remove(from)) return;
      session.serverKeys[from] = info.$1;
      session.status[from] = info.$2;
      if (pending.isEmpty && !done.isCompleted) done.complete();
    });
    for (final to in pending.toList()) {
      final sig = schnorrSign(session.secretKey, helloMessage(address, to, key, pass));
      final msg = Uint8List(129)..[0] = _hello;
      msg
        ..setRange(1, 33, fromHex(key))
        ..setRange(33, 65, pass.isEmpty ? _noPass : fromHex(pass))
        ..setRange(65, 129, sig);
      unawaited(link.send(to, msg, from: address));
    }
    await done.future.timeout(const Duration(seconds: 3), onTimeout: () {});
    await sub.cancel();
    // A server that did not answer has no rules: read from it as before,
    // without waiting for it again.
    for (final s in pending) {
      session.status[s] = ReaderStatus.free;
    }
  }

  /// Sends [session]'s signed running total for [server], when it has a
  /// pass and delivered bytes since the last receipt.
  void _sendReceipt(ReaderSession session, String server, {bool force = false}) {
    final pass = session.pass, serverKey = session.serverKeys[server];
    if (pass == null || serverKey == null || !session.sendReceipts) return;
    final total = session.delivered[server] ?? 0, last = session.receipted[server] ?? 0;
    if (total <= last || (!force && total - last < session.receiptEvery)) return;
    session.receipted[server] = total;
    final r = Receipt.sign(session.secretKey, pass, serverKey, total);
    final msg = ByteData(105)
      ..setUint8(0, _receipt)
      ..setUint64(33, total);
    final bytes = msg.buffer.asUint8List()
      ..setRange(1, 33, fromHex(pass))
      ..setRange(41, 105, fromHex(r.sig));
    unawaited(link.send(server, bytes, from: address));
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

class _Reader {
  _Reader(this.key, this.pass, this.status);
  final String key;
  final String? pass;
  final ReaderStatus status;
  int served = 0;
  int receipted = 0;
}

class _Download {
  _Download(
    this.service,
    this.sha,
    this.size,
    this.providers,
    this.target,
    this.onProgress,
    this.cancelled,
    this.reader,
  ) : chunks = size == 0 ? 0 : (size + blobChunk - 1) ~/ blobChunk;

  final BlobService service;
  final String sha;
  final int size;
  final List<String> providers;
  final String target;
  final void Function(int)? onProgress;
  final bool Function()? cancelled;
  final ReaderSession? reader;
  final int chunks;
  final _limits = <LimitReason>{};
  final _waitingReceipts = <String, int>{};

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
    if (reader != null) await service._introduce(reader!, providers);
    if (chunks == 0 || !_have.contains(0)) {
      _finish();
    } else {
      _fill();
    }
    final ticker = Timer.periodic(const Duration(milliseconds: 500), (_) => _tick());
    final r = await _done.future;
    ticker.cancel();
    if (reader != null) {
      for (final p in providers) {
        service._sendReceipt(reader!, p, force: true);
      }
    }
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
      _fail(_limits.isEmpty ? 'Nobody has this file right now.' : _limits.first.message);
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
    _waitingReceipts.remove(from);
    if (reader case final session?) {
      session.delivered[from] = (session.delivered[from] ?? 0) + bytes.length;
      service._sendReceipt(session, from);
    }
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

  /// [from] will serve no more for now: treated as gone, with its reason
  /// kept for the error if nobody else serves.
  void limited(String from, LimitReason why) {
    if (why == LimitReason.receipts &&
        reader != null &&
        (_waitingReceipts[from] = (_waitingReceipts[from] ?? 0) + 1) <= 3) {
      // A pause, not a refusal: sign the receipt now; the chunk is asked
      // again when its request times out.
      service._sendReceipt(reader!, from, force: true);
      return;
    }
    _limits.add(why);
    missing(from);
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
