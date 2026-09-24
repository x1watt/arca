import 'dart:io';

import 'package:flutter/material.dart';

import '../models/kinds.dart';

String formatBytes(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1000 && unit < units.length - 1) {
    value /= 1000;
    unit++;
  }
  final digits = value >= 100 || unit == 0 ? 0 : 1;
  return '${value.toStringAsFixed(digits)} ${units[unit]}';
}

/// "3 minutes ago", "2 days ago", from Unix seconds.
String timeAgo(int unixSeconds) {
  final d = DateTime.now().difference(
    DateTime.fromMillisecondsSinceEpoch(unixSeconds * 1000),
  );
  if (d.inMinutes < 1) return 'just now';
  if (d.inHours < 1) return '${plural(d.inMinutes, 'minute')} ago';
  if (d.inDays < 1) return '${plural(d.inHours, 'hour')} ago';
  if (d.inDays < 30) return '${plural(d.inDays, 'day')} ago';
  if (d.inDays < 365) return '${plural(d.inDays ~/ 30, 'month')} ago';
  return '${plural(d.inDays ~/ 365, 'year')} ago';
}

IconData kindIcon(FileKind kind) => switch (kind) {
  FileKind.document => Icons.description_outlined,
  FileKind.book => Icons.menu_book_outlined,
  FileKind.image => Icons.image_outlined,
  FileKind.audio => Icons.graphic_eq,
  FileKind.video => Icons.movie_outlined,
  FileKind.software => Icons.apps_outlined,
  FileKind.dataset => Icons.table_chart_outlined,
  FileKind.map => Icons.map_outlined,
  FileKind.archive => Icons.folder_zip_outlined,
};

String kindLabel(FileKind kind) =>
    kind.name[0].toUpperCase() + kind.name.substring(1);

/// Square tinted icon used as the leading visual for a file.
class KindAvatar extends StatelessWidget {
  const KindAvatar(this.kind, {super.key, this.size = 44});
  final FileKind kind;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Icon(
        kindIcon(kind),
        color: scheme.onSecondaryContainer,
        size: size * 0.5,
      ),
    );
  }
}

/// A circle's name as a small pill.
class CircleBadge extends StatelessWidget {
  const CircleBadge(this.name, {super.key});
  final String name;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.groups_outlined, size: 13, color: scheme.onSurfaceVariant),
          const SizedBox(width: 4),
          Text(name, style: Theme.of(context).textTheme.labelSmall),
        ],
      ),
    );
  }
}

class SectionTitle extends StatelessWidget {
  const SectionTitle(this.text, {super.key, this.trailing});
  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              text,
              style: Theme.of(context).textTheme.titleSmall
                  ?.copyWith(color: Theme.of(context).colorScheme.primary),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// A centred message for screens with nothing to show yet.
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.text,
    this.action,
  });
  final IconData icon;
  final String title;
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 48, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(height: 16),
              Text(
                title,
                style: theme.textTheme.titleMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                text,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              if (action != null) ...[const SizedBox(height: 20), action!],
            ],
          ),
        ),
      ),
    );
  }
}

/// Shows a short message at the bottom of the screen.
void showMessage(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

/// For features that are designed but not built yet.
void showPrototypeNote(BuildContext context, String action) =>
    showMessage(context, '$action: not available yet');

/// "1 file", "3 files".
String plural(int n, String word) => '$n $word${n == 1 ? '' : 's'}';

/// Opens a file or folder with the system's default application.
Future<void> openWithSystem(BuildContext context, String path) async {
  try {
    final r = Platform.isMacOS
        ? await Process.run('open', [path])
        : Platform.isWindows
        ? await Process.run('explorer', [path])
        : await Process.run('xdg-open', [path]);
    if (r.exitCode != 0 && context.mounted) {
      showMessage(context, 'Could not open $path');
    }
  } on ProcessException {
    if (context.mounted) {
      showMessage(context, 'Opening files is not supported on this device yet');
    }
  }
}
