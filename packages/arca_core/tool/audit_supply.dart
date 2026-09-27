// Checks a node's state adds up (docs/architecture.md, 10, private marcas):
// the private side holds no more than was moved into it (the sum of every
// unspent output's commitment equals the sum of kernel excesses plus the
// private supply times H), and every marca issued is either burned or held
// somewhere (public balances, pools, open passes, the private side).
//
//   dart run tool/audit_supply.dart <chain folder of a profile>
//
// The folder is <profile>/chain, holding config.json and snapshot.json.
import 'dart:convert';
import 'dart:io';

import 'package:arca_core/src/chain/private_tx.dart';
import 'package:arca_core/src/chain/state.dart';
import 'package:arca_core/src/chain/testnet.dart';

void main(List<String> args) {
  final dir = args.single;
  final config = jsonDecode(File('$dir/config.json').readAsStringSync()) as Map;
  final spec = TestnetSpec((config['spec'] as Map).cast<String, Object?>());
  final snap = jsonDecode(File('$dir/snapshot.json').readAsStringSync()) as Map;
  final entries = {
    for (final e in (snap['state'] as Map).entries) e.key as String: (e.value as Map).cast<String, String>(),
  };
  final s = ChainState.fromEntries(spec.params, entries);
  print('height ${s.height}, ${s.outputs.raw.length} unspent private outputs, '
      'private supply ${s.privateSupply}, issued ${s.issued}, burned ${s.burned}');
  final private = auditSupply(s), money = auditMoney(s);
  print('private side: ${private ?? 'adds up'}');
  print('all marcas: ${money ?? 'accounted for'}');
  exit(private == null && money == null ? 0 : 1);
}
