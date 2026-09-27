// A profile's private wallet on the chain worker (docs/architecture.md, 10):
// the outputs it owns, found by scanning the unspent outputs with the scan
// key, and the coins it picks to pay. It holds no spend key: spending asks
// the core to sign each input (private_tx.dart, InputSigner).

import 'dart:convert';
import 'dart:io';

import '../crypto/curve.dart';
import '../crypto/hex.dart';
import 'private_tx.dart';
import 'wallet_keys.dart';

class Wallet {
  Wallet(this.view, this.address, this.file);

  final ViewKeys view;
  final WalletAddress address;
  final File file;

  /// What this wallet owns, by commitment.
  final owned = <String, Owned>{};

  /// Outputs this wallet's own unconfirmed transactions spend, and since
  /// when: a transaction that never makes it into a block frees them after
  /// [spendingFor].
  final _spending = <String, DateTime>{};
  static const spendingFor = Duration(minutes: 5);

  Set<String> get spending => _spending.keys.toSet();

  void markSpending(Iterable<String> commitments) {
    final now = DateTime.now();
    for (final c in commitments) {
      _spending[c] = now;
    }
  }

  /// Change on its way back from this wallet's own transactions, until
  /// the block that holds it is scanned (or [spendingFor] passes).
  final _returning = <BigInt, DateTime>{};

  BigInt get returning => _returning.keys.fold(BigInt.zero, (a, v) => a + v);

  void expectChange(BigInt value) {
    if (value > BigInt.zero) _returning[value] = DateTime.now();
  }

  /// Outputs looked at already, so each is scanned once.
  final _seen = <String>{};

  BigInt get balance =>
      owned.values.where((o) => !_spending.containsKey(o.commitment)).fold(BigInt.zero, (a, o) => a + o.value);

  /// Brings the wallet in line with [outputs] (commitment to entry JSON, all
  /// unspent outputs): scans the new ones, forgets spent ones. True when
  /// what it owns changed.
  bool update(Map<String, String> outputs) {
    var changed = false;
    for (final key in owned.keys.toList()) {
      if (!outputs.containsKey(key)) {
        owned.remove(key);
        _spending.remove(key);
        changed = true;
      }
    }
    final stale = DateTime.now().subtract(spendingFor);
    _spending.removeWhere((_, since) => since.isBefore(stale));
    _returning.removeWhere((_, since) => since.isBefore(stale));
    _seen.removeWhere((k) => !outputs.containsKey(k));
    for (final e in outputs.entries) {
      if (!_seen.add(e.key)) continue;
      final o = find(e.key, e.value);
      if (o != null) {
        owned[e.key] = o;
        _returning.remove(o.value);
        changed = true;
      }
    }
    return changed;
  }

  /// The output [commitment] with [entryJson], if it is this wallet's.
  Owned? find(String commitment, String entryJson) {
    final entry = OutputEntry.fromJson(jsonDecode(entryJson) as Map);
    if (entry == null) return null;
    final t = view.recognise(entry.r, entry.k, entry.tag);
    if (t == null) return null;
    final c = Point.decode(fromHex(commitment));
    final v = c == null ? null : openOutput(c, entry.encryptedValue, t);
    return v == null ? null : Owned(commitment: commitment, value: v, blinding: stealthBlinding(t), t: t);
  }

  /// Coins adding up to at least [amount], largest first; null when the
  /// wallet does not hold that much.
  List<Owned>? pick(BigInt amount) {
    final free = owned.values.where((o) => !_spending.containsKey(o.commitment)).toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final out = <Owned>[];
    var sum = BigInt.zero;
    for (final o in free) {
      if (sum >= amount) break;
      out.add(o);
      sum += o.value;
      if (out.length == maxPrivateInputs) break;
    }
    return sum >= amount ? out : null;
  }

  Future<void> load() async {
    try {
      final j = jsonDecode(await file.readAsString()) as Map;
      for (final o in j['owned'] as List) {
        final x = Owned.fromJson(o as Map);
        owned[x.commitment] = x;
        _seen.add(x.commitment);
      }
    } on Object {
      // Nothing yet, or unreadable: scanning finds it again.
    }
  }

  Future<void> save() async {
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(jsonEncode({'owned': [for (final o in owned.values) o.toJson()]}));
    await tmp.rename(file.path);
  }
}
