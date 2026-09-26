// A circle's own log (whitepaper, section 4): an append-only chain of
// signed entries holding its members, policy, moderators, collections and
// payout table. It carries no money and needs no mining; about once an
// hour a moderator anchors its roots on the global chain, which pins the
// history so it cannot be rewritten.
//
// The seven rules, as the log enforces them:
//  1. Whoever creates the circle (on the chain) is its admin.
//  2. The admin appoints moderators and sets the policy, nothing else.
//  3. Moderators admit and exclude members, with as many moderator
//     signatures as the policy's approvals dial asks.
//  4. (Indexing: moderators sign the index shards; not part of the log.)
//  5. Moderators accept collections, with the same approvals.
//  6. A majority of moderators replaces the admin or removes a moderator.
//     The admin cannot remove moderators.
//  7. Policy can change at any time. With no admin and no moderators the
//     circle is frozen: nothing more can be appended.

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as c;

import '../crypto/hex.dart';
import '../crypto/schnorr.dart';
import 'merkle.dart';
import 'tx.dart' show canonicalJson;

abstract final class LogType {
  static const policy = 'policy';
  static const appoint = 'appoint';
  static const removeModerator = 'removeModerator';
  static const replaceAdmin = 'replaceAdmin';
  static const admit = 'admit';
  static const join = 'join';
  static const exclude = 'exclude';
  static const collection = 'collection';
  static const removeCollection = 'removeCollection';
  static const payout = 'payout';
}

/// The four dials and the rest of a circle's policy.
class CirclePolicy {
  const CirclePolicy({
    this.openJoin = true,
    this.openPublish = true,
    this.publicVisibility = true,
    this.approvals = 1,
    this.disconnectAfterTicks = 6 * 3600,
    this.disconnectedFree = true,
    this.payoutShares = const {'stewards': 45, 'contributors': 45, 'moderators': 10},
  });

  /// Joining: anyone joins by publishing a key, or newcomers wait for
  /// admission.
  final bool openJoin;

  /// Publishing: members' files enter at once, or wait for review.
  final bool openPublish;

  /// Visibility: anyone browses and downloads, or members only.
  final bool publicVisibility;

  /// Approvals: moderator signatures an admission or a collection needs.
  final int approvals;

  /// Cut off from the chain for this long, the circle stops selling passes
  /// and serves everyone for free ([disconnectedFree]) or members only.
  final int disconnectAfterTicks;
  final bool disconnectedFree;

  /// The pool's payout policy: percent to stewards (by sync score), to
  /// contributors (by how much their accepted files are kept and read) and
  /// to moderators and indexers.
  final Map<String, int> payoutShares;

  Map<String, Object?> toJson() => {
    'openJoin': openJoin,
    'openPublish': openPublish,
    'publicVisibility': publicVisibility,
    'approvals': approvals,
    'disconnectAfterTicks': disconnectAfterTicks,
    'disconnectedFree': disconnectedFree,
    'payoutShares': payoutShares,
  };

  factory CirclePolicy.fromJson(Map m) => CirclePolicy(
    openJoin: m['openJoin'] as bool? ?? true,
    openPublish: m['openPublish'] as bool? ?? true,
    publicVisibility: m['publicVisibility'] as bool? ?? true,
    approvals: m['approvals'] as int? ?? 1,
    disconnectAfterTicks: m['disconnectAfterTicks'] as int? ?? 6 * 3600,
    disconnectedFree: m['disconnectedFree'] as bool? ?? true,
    payoutShares: (m['payoutShares'] as Map?)?.cast<String, int>() ?? const {},
  );
}

class LogEntry {
  const LogEntry({
    required this.circle,
    required this.seq,
    required this.prev,
    required this.author,
    required this.type,
    required this.body,
    required this.sig,
    this.approvals = const {},
  });

  final String circle;
  final int seq;

  /// The id of the entry before ('' for the first).
  final String prev;
  final String author;
  final String type;
  final Map<String, Object?> body;
  final String sig;

  /// Further moderators' signatures over [id]: key to signature.
  final Map<String, String> approvals;

  static Uint8List _idBytes(String circle, int seq, String prev, String author, String type, Map body) =>
      Uint8List.fromList(
        c.sha256.convert(utf8.encode(canonicalJson(['arca-log-v1', circle, seq, prev, author, type, body]))).bytes,
      );

  String get id => toHex(_idBytes(circle, seq, prev, author, type, body));

  factory LogEntry.sign(
    List<int> secretKey, {
    required String circle,
    required int seq,
    required String prev,
    required String type,
    Map<String, Object?> body = const {},
  }) {
    final author = toHex(publicKeyOf(secretKey));
    final sig = toHex(schnorrSign(secretKey, _idBytes(circle, seq, prev, author, type, body)));
    return LogEntry(circle: circle, seq: seq, prev: prev, author: author, type: type, body: body, sig: sig);
  }

  /// This entry with one more signature, by [secretKey].
  LogEntry approvedBy(List<int> secretKey) => LogEntry(
    circle: circle,
    seq: seq,
    prev: prev,
    author: author,
    type: type,
    body: body,
    sig: sig,
    approvals: {...approvals, toHex(publicKeyOf(secretKey)): toHex(schnorrSign(secretKey, fromHex(id)))},
  );

  /// Keys whose signatures over this entry are valid, the author first.
  List<String> signers() {
    final msg = fromHex(id);
    bool ok(String key, String sig) {
      try {
        return schnorrVerify(fromHex(key), msg, fromHex(sig));
      } catch (_) {
        return false;
      }
    }

    return [
      if (ok(author, sig)) author,
      for (final e in approvals.entries)
        if (e.key != author && ok(e.key, e.value)) e.key,
    ];
  }

  Map<String, Object?> toJson() => {
    'circle': circle,
    'seq': seq,
    'prev': prev,
    'author': author,
    'type': type,
    'body': body,
    'sig': sig,
    if (approvals.isNotEmpty) 'approvals': approvals,
  };

  factory LogEntry.fromJson(Map m) => LogEntry(
    circle: m['circle'] as String,
    seq: m['seq'] as int,
    prev: m['prev'] as String,
    author: m['author'] as String,
    type: m['type'] as String,
    body: (m['body'] as Map).cast<String, Object?>(),
    sig: m['sig'] as String,
    approvals: (m['approvals'] as Map?)?.cast<String, String>() ?? const {},
  );
}

class LogError implements Exception {
  const LogError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// A collection as the circle lists it: the partitions its files are in,
/// the root of its current version, and whether it is public (only public
/// collections enter the global corpus and earn).
class LogCollection {
  const LogCollection({required this.partitions, required this.root, required this.public});
  final List<int> partitions;
  final String root;
  final bool public;
}

/// The circle as its log says it is now.
class CircleLog {
  CircleLog(this.circle, {required String admin}) : _admin = admin;

  final String circle;
  String _admin;
  final moderators = <String>{};
  final members = <String>{};
  final collections = <String, LogCollection>{};
  var policy = const CirclePolicy();

  /// Cumulative marcas (grains) owed to each member by the pool, from the
  /// latest payout entry.
  final payouts = <String, int>{};
  final entries = <LogEntry>[];

  String get admin => _admin;
  String get head => entries.isEmpty ? '' : entries.last.id;
  int get nextSeq => entries.length;

  /// Rule 7: no admin and no moderators.
  bool get frozen => _admin.isEmpty && moderators.isEmpty;

  /// Replays [entries] from the start; throws [LogError] at the first one
  /// that breaks a rule.
  factory CircleLog.replay(String circle, String admin, Iterable<LogEntry> entries) {
    final log = CircleLog(circle, admin: admin);
    for (final e in entries) {
      log.append(e);
    }
    return log;
  }

  /// Signs and appends an entry by [secretKey], with [approvers] signing it
  /// too; returns it.
  LogEntry write(
    List<int> secretKey,
    String type, [
    Map<String, Object?> body = const {},
    List<List<int>> approvers = const [],
  ]) {
    var e = LogEntry.sign(secretKey, circle: circle, seq: nextSeq, prev: head, type: type, body: body);
    for (final a in approvers) {
      e = e.approvedBy(a);
    }
    append(e);
    return e;
  }

  /// Checks [e] against the rules and applies it, or throws [LogError].
  void append(LogEntry e) {
    if (frozen) throw const LogError('the circle is frozen: no admin and no moderators');
    if (e.circle != circle || e.seq != nextSeq || e.prev != head) throw const LogError('not the next entry');
    final signers = e.signers();
    if (signers.isEmpty || signers.first != e.author) throw const LogError('bad signature');
    final mods = signers.where(moderators.contains).toSet();
    final b = e.body;
    String key() {
      final k = b['key'] as String? ?? '';
      if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(k)) throw const LogError('bad key');
      return k;
    }

    void byAdmin() {
      if (e.author != _admin) throw const LogError('only the admin does this');
    }

    void byModerators() {
      if (!moderators.contains(e.author)) throw const LogError('only moderators do this');
      final needed = policy.approvals.clamp(1, moderators.length);
      if (mods.length < needed) throw LogError('needs $needed moderator approvals, has ${mods.length}');
    }

    void byMajority() {
      if (mods.length * 2 <= moderators.length) {
        throw LogError('needs a majority of the ${moderators.length} moderators, has ${mods.length}');
      }
    }

    switch (e.type) {
      case LogType.policy:
        byAdmin();
        policy = CirclePolicy.fromJson(b);
        if (policy.approvals < 1) throw const LogError('approvals must be at least one');
        final shares = policy.payoutShares.values;
        if (shares.any((s) => s < 0) || shares.fold(0, (a, s) => a + s) != 100) {
          throw const LogError('payout shares must add up to 100');
        }
      case LogType.appoint:
        byAdmin();
        moderators.add(key());
      case LogType.removeModerator:
        byMajority();
        if (!moderators.remove(key())) throw const LogError('not a moderator');
      case LogType.replaceAdmin:
        byMajority();
        final k = b['key'] as String? ?? '';
        _admin = k.isEmpty ? '' : key();
      case LogType.join:
        if (!policy.openJoin) throw const LogError('this circle admits by request');
        if (key() != e.author) throw const LogError('one joins with one\'s own key');
        members.add(e.author);
      case LogType.admit:
        byModerators();
        members.add(key());
      case LogType.exclude:
        byModerators();
        members.remove(key());
      case LogType.collection:
        byModerators();
        final id = b['id'] as String? ?? '';
        if (!RegExp(r'^[a-z0-9][a-z0-9-]{2,62}$').hasMatch(id)) throw const LogError('bad collection id');
        collections[id] = LogCollection(
          partitions: ((b['partitions'] as List?) ?? const []).cast<int>().toSet().toList()..sort(),
          root: b['root'] as String? ?? '',
          public: b['public'] as bool? ?? true,
        );
      case LogType.removeCollection:
        byModerators();
        if (collections.remove(b['id']) == null) throw const LogError('no such collection');
      case LogType.payout:
        byAdmin();
        final table = (b['table'] as Map? ?? const {}).cast<String, int>();
        for (final e in table.entries) {
          if (e.value < (payouts[e.key] ?? 0)) throw const LogError('payout totals only grow');
        }
        payouts.addAll(table);
      default:
        throw LogError('unknown entry ${e.type}');
    }
    entries.add(e);
  }

  /// Roots an anchor carries.
  Uint8List memberRoot() => merkleRoot([for (final k in members.toList()..sort()) leafHash(utf8.encode(k))]);

  Uint8List dataRoot() => merkleRoot([
    for (final id in publicCollections.keys.toList()..sort())
      leafHash(utf8.encode(canonicalJson([id, collections[id]!.root, collections[id]!.partitions]))),
  ]);

  Map<String, LogCollection> get publicCollections => {
    for (final e in collections.entries)
      if (e.value.public) e.key: e.value,
  };

  PayoutTable payoutTable() => PayoutTable(circle, payouts);

  /// The body of an anchor transaction for the log as it stands.
  Map<String, Object?> anchorBody() => {
    'circle': circle,
    'logHead': head,
    'dataRoot': toHex(dataRoot()),
    'memberRoot': toHex(memberRoot()),
    'payoutRoot': toHex(payoutTable().root),
    'collections': {for (final e in publicCollections.entries) e.key: e.value.partitions},
  };
}

/// A pool's payout table: cumulative totals owed per member, committed as
/// one Merkle root. A member claims the difference between its total and
/// what it claimed before, with the proof of its leaf.
class PayoutTable {
  PayoutTable(this.circle, Map<String, int> totals) : keys = totals.keys.toList()..sort(), totals = Map.of(totals);

  final String circle;
  final List<String> keys;
  final Map<String, int> totals;

  static Uint8List leaf(String circle, String key, int total) => leafHash(utf8.encode('arca-payout|$circle|$key|$total'));

  List<Uint8List> get _leaves => [for (final k in keys) leaf(circle, k, totals[k]!)];

  Uint8List get root => merkleRoot(_leaves);

  /// The body of a claim transaction by [key].
  Map<String, Object?> claimBody(String key) {
    final i = keys.indexOf(key);
    if (i < 0) throw ArgumentError('$key is not in the table');
    return {
      'circle': circle,
      'total': totals[key],
      'index': i,
      'count': keys.length,
      'path': [
        for (final (h, right) in merkleProof(_leaves, i)) [toHex(h), right],
      ],
    };
  }
}

/// Splits [amount] by the circle's payout [shares] (percent per group),
/// and within each group by [weights] (group to member to weight), adding
/// to the cumulative [totals]. Rounds down: never pays out more than came
/// in. Returns the new totals.
Map<String, int> distribute(
  int amount,
  Map<String, int> shares,
  Map<String, Map<String, int>> weights,
  Map<String, int> totals,
) {
  final out = Map.of(totals);
  for (final group in shares.keys.toList()..sort()) {
    final w = weights[group] ?? const {};
    final sum = w.values.fold(0, (a, b) => a + b);
    if (sum == 0) continue;
    final part = BigInt.from(amount) * BigInt.from(shares[group]!) ~/ BigInt.from(100);
    for (final k in w.keys.toList()..sort()) {
      out[k] = (out[k] ?? 0) + (part * BigInt.from(w[k]!) ~/ BigInt.from(sum)).toInt();
    }
  }
  return out;
}

/// What a moderator signs to agree to a change of admin or moderators on
/// the chain (rule 6).
Uint8List governanceMessage(String circle, String admin, List<String> moderators) => Uint8List.fromList(
  c.sha256.convert(utf8.encode(canonicalJson(['arca-gov-v1', circle, admin, [...moderators]..sort()]))).bytes,
);
