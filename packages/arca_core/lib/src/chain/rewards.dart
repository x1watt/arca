// A day's new marcas (whitepaper, section 8), counted as holding proofs
// arrive and paid in small steps after the day ends, so that every step of
// it can be shown wrong to a light client with a few entries (fraud.dart).
//
// Storage budget (30%): per partition, deduplicated by construction, split
// by size and by the replication curve among the partition's provers.
//
// Interest budget (70%): per collection. A collection's interest is its
// genesis seed, plus what non-members burned for it over the last 30 days,
// plus a third of the standing of the keepers from other circles who keep
// it, each divided by the number of collections they kept the day before.
// A keeper's standing is its share, on the curve, of the interest of what
// it keeps; the budget is paid in proportion to it, so standing flows
// outward one hop per day.
//
// How: each holding proof updates the day's running totals (provers per
// partition, the storage weight, keepers and interest per collection, the
// sum of interest shares) and the keeper's own record of the day. When the
// day is over, keepers are settled from their records and the totals a
// few at a time, at the start of the next blocks, and the day's totals
// are then removed the same way. Every step touches the keepers it
// settles, the totals and their circles' pools, never the whole state.
//
// Every payment goes to the pool of the circle the keeper's declaration
// named when it proved. A circle whose last anchor is more than a day old
// at the end of the day is cut off: what its keepers earned that day is
// not created. What nobody earned is never created.
//
// The day's running totals live in the 'tally' namespace:
//   W:<d>          storage weight: sum over partitions of size x curve
//   S:<d>          sum over collections of interest x curve / 100
//   p:<d>:<p>      provers of partition p
//   c:<d>:<C>      [keepers, interest] of collection C
//   k:<d>:<key>    the keeper's day: [[partition, circle]...], [collection...]
//   q:<d>:<i>      the i-th keeper to settle; qn:<d> how many, qc:<d> done
//   l:<d>:<i>      the i-th total to remove afterwards; ln:<d>, lc:<d>
//   pq:<d>:<i>     passes that close as day d starts; pqn:<d>, pqc:<d>
//   pc:<p>         the collections partition p belongs to

import 'params.dart';
import 'passes.dart';
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

BigInt _big(Object? v) => v == null ? BigInt.zero : BigInt.parse('$v');
int _int(Object? v) => v == null ? 0 : (v as num).toInt();

/// A keeper's standing: (day, amount, collections kept that day).
(int, int, int) standingOf(ChainState s, String key) {
  final v = s.standing[key];
  return v == null ? (-1, 0, 0) : (v[0], v[1], v[2]);
}

/// A member's sync score in [circle] as of [day]: a seventh less for each
/// day since it was last earned.
int syncScoreOf(ChainState s, String circle, String key, int day) {
  final v = s.syncScores['$circle $key'];
  if (v == null || day - v[0] > 90) return 0;
  var score = v[1];
  for (var d = v[0]; d < day && score > 0; d++) {
    score -= score ~/ ChainParams.syncScoreDecay;
  }
  return score;
}

/// Whether [key] missed a holding proof it owed before [day]: every
/// partition it declared before yesterday must have been proven yesterday
/// or today. A keeper that missed one may post no more holding proofs, so
/// earns nothing, until it declares again, which drops what it had.
bool lapsed(ChainState s, String key, int day) {
  final declared = s.declarations[key];
  if (declared == null) return false;
  final since = s.declaredOn[key] ?? const {};
  final proven = s.provenOn[key] ?? const {};
  for (final p in declared.keys) {
    if ((since[p] ?? day) < day - 1 && (proven[p] ?? -1) < day - 1) return true;
  }
  return false;
}

/// Drops everything [key] kept and its standing and scores (a missed proof).
void dropKeeper(ChainState s, String key) {
  final declared = s.declarations.remove(key);
  if (declared == null) return;
  s.keepers--;
  s.declaredOn.remove(key);
  s.provenOn.remove(key);
  s.standing.remove(key);
  for (final circle in declared.values.toSet()) {
    s.syncScores.remove('$circle $key');
  }
}

List<String> _pcOf(ChainState s, int p) => [for (final c in s.tally['pc:$p'] as List? ?? const []) '$c'];

/// Updates which collections partition [p] belongs to (anchors call it).
void indexCollection(ChainState s, String id, List<int> partitions, {required bool add}) {
  for (final p in partitions) {
    final list = _pcOf(s, p)..remove(id);
    if (add) list.add(id);
    if (list.isEmpty) {
      s.tally.remove('pc:$p');
    } else {
      s.tally['pc:$p'] = list..sort();
    }
  }
}

void _addTotal(ChainState s, String key, BigInt delta) {
  if (delta == BigInt.zero) return;
  s.tally[key] = '${_big(s.tally[key]) + delta}';
}

/// Remembers a total of [day] to remove once the day is settled.
void _toRemove(ChainState s, int day, String key) {
  final n = _int(s.tally['ln:$day']);
  s.tally['l:$day:$n'] = key;
  s.tally['ln:$day'] = n + 1;
}

/// Counts [key]'s holding proof for partition [p], for the circle its
/// declaration names, into today's totals. A second proof of the same
/// partition on the same day changes nothing.
void recordProof(ChainState s, String key, int p, String circle) {
  final d = s.day;
  final recKey = 'k:$d:$key';
  final rec = s.tally[recKey] as List?;
  final parts = [for (final e in rec?[0] as List? ?? const []) (_int((e as List)[0]), '${e[1]}')];
  if (parts.any((e) => e.$1 == p)) return;
  if (rec == null) {
    // First proof of the day: queue the keeper for settlement.
    final n = _int(s.tally['qn:$d']);
    s.tally['q:$d:$n'] = key;
    s.tally['qn:$d'] = n + 1;
    if (n == 0) {
      if (s.settleFrom < 0 || s.settleFrom > d) s.settleFrom = d;
      _toRemove(s, d, 'W:$d');
      _toRemove(s, d, 'S:$d');
    }
  }
  parts.add((p, circle));
  // Storage: one more copy of p.
  final size = p < s.partitionSizes.length ? s.partitionSizes[p] : 0;
  final nKey = 'p:$d:$p';
  final n = _int(s.tally[nKey]);
  if (n == 0) _toRemove(s, d, nKey);
  s.tally[nKey] = n + 1;
  _addTotal(s, 'W:$d', BigInt.from(size) * BigInt.from(curveTotal(n + 1) - curveTotal(n)));
  // Interest: collections this proof completes for the keeper today.
  final cols = [for (final c in rec?[1] as List? ?? const []) '$c'];
  final proven = {for (final e in parts) e.$1};
  for (final id in _pcOf(s, p)) {
    final c = s.collections[id];
    if (c == null || cols.contains(id) || !c.partitions.every(proven.contains)) continue;
    cols.add(id);
    final cKey = 'c:$d:$id';
    final tally = s.tally[cKey] as List?;
    var keepers = _int(tally?[0]);
    var interest = tally == null ? _baseline(s, id, d) : _big(tally[1]);
    if (tally == null) _toRemove(s, d, cKey);
    final before = interest * BigInt.from(curveTotal(keepers)) ~/ BigInt.from(100);
    // A keeper from another circle passes on a third of its standing of
    // the day before, split over the collections it kept then.
    final declaredFor = parts.firstWhere((e) => e.$1 == c.partitions.first).$2;
    if (declaredFor != c.circle) {
      final (sDay, amount, kept) = standingOf(s, key);
      if (sDay == d - 1 && kept > 0) {
        interest += BigInt.from(amount) ~/ BigInt.from(ChainParams.standingPassOn * kept);
      }
    }
    keepers++;
    final after = interest * BigInt.from(curveTotal(keepers)) ~/ BigInt.from(100);
    s.tally[cKey] = [keepers, '$interest'];
    _addTotal(s, 'S:$d', after - before);
  }
  s.tally[recKey] = [
    [
      for (final e in parts) [e.$1, e.$2],
    ],
    cols,
  ];
}

/// A collection's interest on [day] before anyone kept it: its seed and
/// what non-members burned for it over the window.
BigInt _baseline(ChainState s, String id, int day) {
  var interest = BigInt.from(s.collections[id]?.seed ?? 0);
  s.burnsFor[id]?.forEach((d, amount) {
    if (d > day - ChainParams.interestWindowDays && d <= day) interest += BigInt.from(amount);
  });
  return interest;
}

/// A burn for [collection] today raises its interest at once for those
/// already keeping it (later keepers count it in the baseline).
void noteBurn(ChainState s, String collection, int amount) {
  final cKey = 'c:${s.day}:$collection';
  final tally = s.tally[cKey] as List?;
  if (tally == null) return;
  final keepers = _int(tally[0]);
  s.tally[cKey] = [keepers, '${_big(tally[1]) + BigInt.from(amount)}'];
  _addTotal(s, 'S:${s.day}', BigInt.from(amount) * BigInt.from(curveTotal(keepers)) ~/ BigInt.from(100));
}

/// Settlement steps a block takes: enough to settle a day's keepers within
/// half a day of blocks (and remove its totals), at least eight, plus the
/// passes due. Each step is its own entry in the block's trace.
int settleBudget(ChainState s) {
  var budget = 8;
  final d = s.settleFrom;
  if (d >= 0 && d < s.day) {
    final work = _int(s.tally['qn:$d']) + _int(s.tally['ln:$d']);
    final blocks = s.params.blocksPerDay ~/ 2;
    final need = blocks <= 0 ? work : (work + blocks - 1) ~/ blocks;
    if (need > budget) budget = need;
  }
  return budget;
}

/// One step of settling: closes a pass due, pays one keeper of a day that
/// ended, or removes one of a settled day's totals. False, with nothing
/// changed, when there is nothing to do; each step also does the
/// bookkeeping its item finishes, so a step that finds nothing changes
/// nothing (every change is in some step's trace entry).
bool settleOne(ChainState s) {
  if (_closeOnePass(s)) return true;
  final d = s.settleFrom;
  if (d < 0 || d >= s.day) return false;
  final queued = _int(s.tally['qn:$d']);
  final done = _int(s.tally['qc:$d']);
  if (done < queued) {
    _settleKeeper(s, d, '${s.tally['q:$d:$done']}');
    s.tally.remove('q:$d:$done');
    s.tally['qc:$d'] = done + 1;
  } else {
    // Every keeper paid: remove the day's totals, one at a time.
    final removed = _int(s.tally['lc:$d']);
    s.tally.remove('${s.tally['l:$d:$removed']}');
    s.tally.remove('l:$d:$removed');
    s.tally['lc:$d'] = removed + 1;
  }
  if (_int(s.tally['qc:$d']) >= queued && _int(s.tally['lc:$d']) >= _int(s.tally['ln:$d'])) {
    // The day is settled: on to the next day with keepers.
    for (final k in ['qn:$d', 'qc:$d', 'ln:$d', 'lc:$d']) {
      s.tally.remove(k);
    }
    s.settleFrom = -1;
    for (var next = d + 1; next <= s.day; next++) {
      if (s.tally['qn:$next'] != null) {
        s.settleFrom = next;
        break;
      }
    }
  }
  return true;
}

/// A block's worth of settlement steps at once (tests, tools).
void settleStep(ChainState s) {
  for (var i = settleBudget(s); i > 0 && settleOne(s); i--) {}
}

void _settleKeeper(ChainState s, int d, String key) {
  final rec = s.tally.remove('k:$d:$key') as List?;
  if (rec == null) return;
  final issuance = s.params.issuanceOn(d);
  final storageBudget = BigInt.from(issuance * ChainParams.storageShare ~/ 100);
  final interestBudget = BigInt.from(issuance * ChainParams.interestShare ~/ 100);
  final dayEnd = s.genesisTick + (d + 1) * s.params.dayTicks;
  final w = _big(s.tally['W:$d']);
  final sum = _big(s.tally['S:$d']);
  final parts = [for (final e in rec[0] as List) (_int((e as List)[0]), '${e[1]}')];
  final today = <String, int>{}; // circle to sync score earned today
  for (final (p, circle) in parts) {
    final n = _int(s.tally['p:$d:$p']);
    final size = p < s.partitionSizes.length ? s.partitionSizes[p] : 0;
    if (w > BigInt.zero && n > 0) {
      final amount = storageBudget * BigInt.from(size) * BigInt.from(curveTotal(n)) ~/ w ~/ BigInt.from(n);
      _pay(s, circle, dayEnd, amount.toInt());
    }
    // Sync score: ten copies' weight shared among the copies.
    today[circle] = (today[circle] ?? 0) + (n == 0 ? 0 : size * ChainParams.targetCopies ~/ n);
  }
  var standing = BigInt.zero;
  final cols = [for (final c in rec[1] as List) '$c'];
  for (final id in cols) {
    final c = s.collections[id];
    final tally = s.tally['c:$d:$id'] as List?;
    if (c == null || tally == null) continue;
    final share = curveShare(_big(tally[1]), _int(tally[0]));
    final circle = parts.firstWhere((e) => e.$1 == c.partitions.first).$2;
    if (sum > BigInt.zero && s.isLive(c.circle, dayEnd)) {
      standing += share;
      _pay(s, circle, dayEnd, (interestBudget * share ~/ sum).toInt());
    }
    if (circle == c.circle) {
      // A whole collection of the circle kept: half its size at ten copies.
      final size = c.partitions.fold(0, (a, p) => a + (p < s.partitionSizes.length ? s.partitionSizes[p] : 0));
      today[circle] = (today[circle] ?? 0) + size * ChainParams.targetCopies ~/ 2;
    }
  }
  s.standing[key] = [d, standing.toInt(), cols.length];
  for (final e in today.entries) {
    s.syncScores['${e.key} $key'] = [d, syncScoreOf(s, e.key, key, d) + e.value];
  }
}

void _pay(ChainState s, String circle, int dayEnd, int amount) {
  final c = s.circles[circle];
  if (c == null || amount <= 0 || !s.isLive(circle, dayEnd)) return;
  c.pool += amount;
  s.issued += amount;
}

// ---- Passes ----

/// The day at whose start a pass ending at [expires] closes (its
/// settlement window over).
int passCloseDay(ChainState s, int expires) {
  final t = expires + s.params.passSettleTicks - s.genesisTick;
  return t <= 0 ? 0 : (t + s.params.dayTicks - 1) ~/ s.params.dayTicks;
}

/// Queues pass [id] to close at the start of [day].
void queuePass(ChainState s, String id, int day) {
  final n = _int(s.tally['pqn:$day']);
  s.tally['pq:$day:$n'] = id;
  s.tally['pqn:$day'] = n + 1;
  if (s.passFrom < 0 || s.passFrom > day) s.passFrom = day;
}

/// A pass closes at most a few days after it is bought, so the next day
/// with passes queued is looked for a few days ahead only.
const _passLookahead = 4;

bool _closeOnePass(ChainState s) {
  final d = s.passFrom;
  if (d < 0 || d > s.day) return false;
  final queued = _int(s.tally['pqn:$d']);
  final done = _int(s.tally['pqc:$d']);
  closePass(s, '${s.tally['pq:$d:$done']}');
  s.tally.remove('pq:$d:$done');
  s.tally['pqc:$d'] = done + 1;
  if (done + 1 >= queued) {
    // The day's passes are closed: on to the next day with passes.
    s.tally.remove('pqn:$d');
    s.tally.remove('pqc:$d');
    s.passFrom = -1;
    for (var next = d + 1; next <= d + _passLookahead + 1; next++) {
      if (s.tally['pqn:$next'] != null) {
        s.passFrom = next;
        break;
      }
    }
  }
  return true;
}
