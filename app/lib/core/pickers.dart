// System file and folder pickers.

import 'package:file_selector/file_selector.dart';

/// A folder chosen by the user, or null when cancelled.
Future<String?> pickFolder({String? title}) =>
    getDirectoryPath(confirmButtonText: title ?? 'Choose');

/// Files chosen by the user; empty when cancelled.
Future<List<String>> pickFiles() async => [
  for (final f in await openFiles()) f.path,
];

/// One file chosen by the user, or null when cancelled.
Future<String?> pickFile() async => (await openFile())?.path;
