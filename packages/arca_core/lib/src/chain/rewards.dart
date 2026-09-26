// A day's new marcas (whitepaper, section 8), paid when the day closes to
// the circles whose stewards proved their keeping that day.
//
// Storage budget (30%): per partition, deduplicated by construction, split
// by size and by the replication curve among the partition's provers.
//
// Interest budget (70%): per collection. A collection's interest is its
// genesis seed, plus what non-members burned for it over the last 30 days,
// plus a third of the standing of the stewards from other circles who keep
// it, each divided by the number of collections they keep. A steward's
// standing is its share, on the curve, of the interest of what it keeps;
// the budget is paid in proportion to it. Standing is recomputed daily
// from the day before, so it flows outward one hop per day.
//
// Every payment goes to the pool of the circle the steward's declaration
// names. What nobody earned is never created.

import 'params.dart';
import 'state.dart';

/// The replication curve: what [keepers] copies earn together, in
/// hundredths of what the target number of copies earns. The reward per
/// copy rises up to the target, and the total is frozen beyond it.
int curveTotal(int keepers) {
  final n = keepers < ChainParams.targetCopies ? keepers : ChainParams.targetCopies;
  return n * n * 100 ~/ (ChainParams.targetCopies * ChainParams.targetCopies);
}

/// What one of [keepers] copies earns of [amount] on the curve.
BigInt curveShare(BigInt amount, int keepers) =>
    keepers == 0 ? BigInt.zero : amount * BigInt.from(curveTotal(keepers)) ~/ BigInt.from(100 * keepers);

/// Pays [day]'s issuance to the stewards who proved all of it, and
/// recomputes standing. Called as the day closes, after stewards who
/// missed a proof were dropped.
void settleDay(ChainState s, int day) {
  final issuance = s.params.issuanceOn(day);
  final storageBudget = BigInt.from(issuance * ChainParams.storageShare ~/ 100);
  final interestBudget = BigInt.from(issuance * ChainParams.interestShare ~/ 100);

  // Who proved which partition today, in key order so every node sums alike.
  final provers = <int, List<String>>{};
  for (final steward in (s.declarations.keys.toList()..sort())) {
    final proven = s.provenOn[steward] ?? const {};
    for (final p in s.declarations[steward]!.keys) {
      if (proven[p] == day) (provers[p] ??= []).add(steward);
    }
  }

  // Storage: partitions weighted by size and by the curve.
  final weights = <int, BigInt>{};
  var total = BigInt.zero;
  for (final e in provers.entries) {
    final size = e.key < s.partitionSizes.length ? s.partitionSizes[e.key] : 0;
    final w = BigInt.from(size) * BigInt.from(curveTotal(e.value.length));
    weights[e.key] = w;
    total += w;
  }
  if (total > BigInt.zero) {
    for (final p in (provers.keys.toList()..sort())) {
      final keepers = provers[p]!;
      final each = storageBudget * weights[p]! ~/ total ~/ BigInt.from(keepers.length);
      for (final steward in keepers) {
        _pay(s, s.declarations[steward]![p]!, each.toInt());
      }
    }
  }

  // Interest: which collections each steward kept whole today.
  final keptBy = <String, List<String>>{};
  final keptCount = <String, int>{};
  for (final id in (s.collections.keys.toList()..sort())) {
    final parts = s.collections[id]!.partitions;
    if (parts.isEmpty) continue;
    final keepers = [
      for (final steward in provers[parts.first] ?? const <String>[])
        if (parts.every((p) => provers[p]?.contains(steward) ?? false)) steward,
    ];
    if (keepers.isEmpty) continue;
    keptBy[id] = keepers;
    for (final k in keepers) {
      keptCount[k] = (keptCount[k] ?? 0) + 1;
    }
  }
  final from = day - ChainParams.interestWindowDays + 1;
  final shares = <(String, String), BigInt>{}; // (steward, collection)
  final standing = <String, BigInt>{};
  var sum = BigInt.zero;
  for (final e in keptBy.entries) {
    final c = s.collections[e.key]!;
    var interest = BigInt.from(c.seed);
    s.burnsFor[e.key]?.forEach((d, amount) {
      if (d >= from && d <= day) interest += BigInt.from(amount);
    });
    for (final k in e.value) {
      if (s.declarations[k]![c.partitions.first] != c.circle) {
        interest += BigInt.from(s.standing[k] ?? 0) ~/ BigInt.from(ChainParams.standingPassOn * keptCount[k]!);
      }
    }
    final each = curveShare(interest, e.value.length);
    if (each == BigInt.zero) continue;
    for (final k in e.value) {
      shares[(k, e.key)] = each;
      standing[k] = (standing[k] ?? BigInt.zero) + each;
      sum += each;
    }
  }
  if (sum > BigInt.zero) {
    final keys = shares.keys.toList()..sort((a, b) => a.$1 != b.$1 ? a.$1.compareTo(b.$1) : a.$2.compareTo(b.$2));
    for (final key in keys) {
      final (steward, id) = key;
      final circle = s.declarations[steward]![s.collections[id]!.partitions.first]!;
      _pay(s, circle, (interestBudget * shares[key]! ~/ sum).toInt());
    }
  }
  s.standing
    ..clear()
    ..addAll({for (final e in standing.entries) e.key: e.value.toInt()});

  // Burns older than the window no longer count.
  for (final id in s.burnsFor.keys.toList()) {
    s.burnsFor[id]!.removeWhere((d, _) => d <= day + 1 - ChainParams.interestWindowDays);
    if (s.burnsFor[id]!.isEmpty) s.burnsFor.remove(id);
  }
}

void _pay(ChainState s, String circle, int amount) {
  final c = s.circles[circle];
  if (c == null || amount <= 0) return;
  c.pool += amount;
  s.issued += amount;
}
