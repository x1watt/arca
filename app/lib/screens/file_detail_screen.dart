import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/core_client.dart';
import '../models/kinds.dart';
import '../widgets/cards.dart';
import '../widgets/comments.dart';
import '../widgets/media_player.dart';
import '../widgets/subtitles.dart';
import '../widgets/common.dart';
import 'metadata_editor_screen.dart';

Future<void> openMetadataEditor(BuildContext context, FileView file) =>
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => MetadataEditorScreen(file: file),
      ),
    );

/// A file's page. It follows the library state, so edits show at once.
class FileDetailScreen extends StatelessWidget {
  const FileDetailScreen({super.key, required this.file});
  final FileView file;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: Core.instance.state,
      builder: (context, state, _) {
        final current = state
            ?.collection(file.collectionId)
            ?.files
            .where((f) => f.path == file.path)
            .firstOrNull;
        if (current == null) {
          return Scaffold(
            appBar: AppBar(),
            body: const EmptyState(
              icon: Icons.hide_source,
              title: 'This file is no longer in the collection',
              text: '',
            ),
          );
        }
        return _Detail(
          file: current,
          circleName: state!.commons.name,
          subtitles: state.subtitles,
        );
      },
    );
  }
}

class _Detail extends StatelessWidget {
  const _Detail({
    required this.file,
    required this.circleName,
    required this.subtitles,
  });
  final FileView file;
  final String circleName;
  final SubtitleStatus subtitles;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(file.name, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: 'Edit details',
            icon: const Icon(Icons.edit_note),
            onPressed: () => openMetadataEditor(context, file),
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900),
          child: ListView(
            padding: const EdgeInsets.only(bottom: 32),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 520),
                  child: switch (kindForMime(file.mime)) {
                    FileKind.video || FileKind.audio => MediaPlayer(file: file),
                    _ => FileThumbnail(file),
                  },
                ),
              ),
              if (kindForMime(file.mime) case FileKind.video || FileKind.audio)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: SubtitlePanel(file: file, status: subtitles),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      file.displayTitle,
                      style: theme.textTheme.headlineSmall,
                    ),
                    if (file.description.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(file.description, style: theme.textTheme.bodyLarge),
                    ],
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        InkWell(
                          onTap: () => openCircle(context),
                          child: CircleBadge(circleName),
                        ),
                        InkWell(
                          onTap: () =>
                              openCollection(context, file.collectionId),
                          child: Text(
                            'in ${file.collectionName}',
                            style: theme.textTheme.bodySmall?.copyWith(
                              decoration: TextDecoration.underline,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        FilledButton.icon(
                          onPressed: () =>
                              openWithSystem(context, file.absolutePath),
                          icon: const Icon(Icons.open_in_new),
                          label: const Text('Open'),
                        ),
                        OutlinedButton.icon(
                          onPressed: () {
                            final dir = file.absolutePath.substring(
                              0,
                              file.absolutePath.lastIndexOf('/'),
                            );
                            openWithSystem(context, dir);
                          },
                          icon: const Icon(Icons.folder_open_outlined),
                          label: const Text('Show in folder'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              if (file.tags.isNotEmpty) ...[
                const SectionTitle('Tags'),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final t in file.tags)
                        Chip(
                          label: Text(t),
                          visualDensity: VisualDensity.compact,
                        ),
                    ],
                  ),
                ),
              ],
              const SectionTitle('Details'),
              _Field(
                'Type',
                '${kindLabel(kindForMime(file.mime))}  (${file.mime})',
              ),
              _Field('Size', '${formatBytes(file.size)}  (${file.size} bytes)'),
              _Field('Added', timeAgo(file.addedAt)),
              _Field('On disk', file.absolutePath, mono: true),
              const SectionTitle('Computed from the file'),
              _Field('SHA-256', file.sha256, mono: true, copy: true),
              _Field('SHA-1', file.sha1, mono: true, copy: true),
              const Divider(height: 32),
              CommentsSection(target: file.target),
            ],
          ),
        ),
      ),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field(this.label, this.value, {this.mono = false, this.copy = false});
  final String label;
  final String value;
  final bool mono;
  final bool copy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 110,
            child: Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: mono
                  ? theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace')
                  : theme.textTheme.bodyMedium,
            ),
          ),
          if (copy)
            IconButton(
              tooltip: 'Copy',
              icon: const Icon(Icons.copy, size: 16),
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: value));
                if (context.mounted) showMessage(context, '$label copied');
              },
            ),
        ],
      ),
    );
  }
}
