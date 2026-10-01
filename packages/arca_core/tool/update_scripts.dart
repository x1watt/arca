// Writes the updater's swap scripts (lib/src/update/install.dart) into a
// folder, so the release workflow can try them on a real Windows and Linux
// bundle.
//
//   dart run tool/update_scripts.dart <folder>
import 'dart:io';

import 'package:arca_core/arca_core.dart';

Future<void> main(List<String> args) async {
  final dir = Directory(args.isEmpty ? '.' : args.first);
  await dir.create(recursive: true);
  await File('${dir.path}/arca-update.sh').writeAsString(unixSwapScript);
  await File('${dir.path}/arca-update.ps1').writeAsString(windowsSwapScript);
  print('wrote ${dir.path}/arca-update.sh and ${dir.path}/arca-update.ps1');
}
