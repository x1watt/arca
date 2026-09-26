// Who may read how much from this device (whitepaper, section 9), and a
// reader's side of it.
//
// Members whose sync score reaches the circle's threshold read freely and
// first; pass holders read as long as they keep signing running byte
// totals (receipts) the server later settles on the chain; everyone else
// gets a free allowance per reader key per day, and all free readers
// together share a daily cap, so making many keys only competes for that
// share. Nothing about timing or load ever leaves the device.

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as c;

/// The server's rules; a [BlobService] without them serves everyone.
class ServingRules {
  const ServingRules({
    required this.serverKey,
    required this.freeAllowance,
    required this.freeTotal,
    required this.passValid,
    required this.isMember,
    this.receiptSlack = 1 << 20,
    this.slots = 16,
  });

  /// This server's key (hex): receipts name it; it settles passes.
  final String serverKey;

  /// Free bytes per reader key per day, and for all free readers together.
  final int freeAllowance;
  final int freeTotal;

  /// Whether [pass] is an active pass of [reader] for what this server
  /// holds (checked on the chain).
  final Future<bool> Function(String reader, String pass) passValid;

  /// Whether [reader]'s sync score gives it member access.
  final bool Function(String reader) isMember;

  /// Bytes a pass holder may be served beyond its latest receipt (plus a
  /// quarter of what it was served, for chunks lost and sent again). Must
  /// exceed what a reader has in flight (8 chunks of 24 KiB).
  final int receiptSlack;

  /// Chunks served at once; the rest wait, members first, then passes.
  final int slots;
}

/// How a server treats a reader.
enum ReaderStatus { free, pass, member }

/// Why a server stopped serving a reader.
enum LimitReason {
  allowance('The free reading allowance for today is used up.'),
  freeShare('The server gives no more free reading today.'),
  receipts('The server is waiting for the reader\'s receipts.');

  const LimitReason(this.message);
  final String message;
}

/// What a reader signs to say "this key and pass are mine" to one server.
Uint8List helloMessage(String readerAddress, String serverAddress, String key, String pass) =>
    Uint8List.fromList(c.sha256.convert(utf8.encode('arca-hello-v1|$readerAddress|$serverAddress|$key|$pass')).bytes);

/// A reader's key and, when it bought one, its pass; kept across
/// downloads so each server's running total keeps growing.
class ReaderSession {
  ReaderSession(this.secretKey, {this.pass, this.receiptEvery = 256 * 1024, this.sendReceipts = true});

  final List<int> secretKey;

  /// The id of an active pass (hex), or null to read on the free allowance.
  final String? pass;
  final int receiptEvery;

  /// For tests: a reader that never signs receipts.
  final bool sendReceipts;

  /// Per server address: its key and how it treats us (from its welcome),
  /// bytes it delivered under the pass, and the total last receipted.
  final serverKeys = <String, String>{};
  final status = <String, ReaderStatus>{};
  final delivered = <String, int>{};
  final receipted = <String, int>{};
}
