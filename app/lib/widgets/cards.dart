import 'dart:io';

import 'package:flutter/material.dart';

import '../core/core_client.dart';
import '../core/pickers.dart';
import '../models/kinds.dart';
import '../screens/circle_screen.dart';
import '../screens/collection_browser_screen.dart';
import '../screens/file_detail_screen.dart';
import 'common.dart';

// Placeholder gradients for files without a picture to show.
const _palettes = [
  [Color(0xFF1F4E5F), Color(0xFF3F8F8A)],
  [Color(0xFF4A2F5E), Color(0xFF9B5E8C)],
  [Color(0xFF5E3B1F), Color(0xFFC08A3E)],
  [Color(0xFF1F3A5E), Color(0xFF4F7BC0)],
  [Color(0xFF2F5E2F), Color(0xFF7BAF5A)],
  [Color(0xFF5E1F2A), Color(0xFFC0505E)],
];

List<Color> paletteFor(String key) =>
    _palettes[key.codeUnits.fold(0, (a, b) => (a * 31 + b) & 0x7fffffff) %
        _palettes.length];

void openFile(BuildContext context, FileView file) => Navigator.of(
  context,
).push(MaterialPageRoute<void>(builder: (_) => FileDetailScreen(file: file)));

void openCollection(BuildContext context, String collectionId) =>
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => CollectionBrowserScreen(collectionId: collectionId),
      ),
    );

void openCircle(BuildContext context) =>
    Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => const CircleScreen()));

/// 16:9 preview: the picture itself for images on disk, the still frame
/// for videos (turning into a short animation while the mouse is over it,
/// like a video site), otherwise a gradient with the file type's icon.
class FileThumbnail extends StatefulWidget {
  const FileThumbnail(
    this.file, {
    super.key,
    this.badge = true,
    this.animateOnHover = true,
  });
  final FileView file;
  final bool badge;
  final bool animateOnHover;

  @override
  State<FileThumbnail> createState() => _FileThumbnailState();
}

class _FileThumbnailState extends State<FileThumbnail> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final file = widget.file;
    final kind = kindForMime(file.mime);
    final isPicture =
        kind == FileKind.image &&
        file.mime != 'image/svg+xml' &&
        file.mime != 'image/tiff';
    final still = isPicture ? file.absolutePath : file.still;
    final showAnimated =
        widget.animateOnHover && _hover && file.animated != null;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AspectRatio(
        aspectRatio: 16 / 9,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Stack(
            fit: StackFit.expand,
            children: [
              TypePlaceholder(kind: kind, seed: file.sha256),
              if (still != null)
                Image.file(
                  File(still),
                  fit: BoxFit.cover,
                  cacheWidth: 640,
                  errorBuilder: (_, _, _) => const SizedBox.shrink(),
                ),
              if (showAnimated)
                Image.file(
                  File(file.animated!),
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                  errorBuilder: (_, _, _) => const SizedBox.shrink(),
                ),
              if (kind == FileKind.video && !showAnimated && widget.badge)
                const Positioned(
                  left: 8,
                  bottom: 8,
                  child: OverlayBadge('Video', icon: Icons.play_arrow),
                ),
              if (widget.badge)
                Positioned(
                  right: 8,
                  bottom: 8,
                  child: OverlayBadge(formatBytes(file.size)),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A gradient with the file type's icon, for files without a picture.
class TypePlaceholder extends StatelessWidget {
  const TypePlaceholder({super.key, required this.kind, required this.seed});
  final FileKind kind;
  final String seed;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: paletteFor(seed),
        ),
      ),
      child: Stack(
        children: [
          Positioned(
            right: -12,
            bottom: -18,
            child: Icon(
              kindIcon(kind),
              size: 120,
              color: Colors.white.withValues(alpha: 0.12),
            ),
          ),
          Center(
            child: Icon(
              kindIcon(kind),
              size: 44,
              color: Colors.white.withValues(alpha: 0.85),
            ),
          ),
        ],
      ),
    );
  }
}

class OverlayBadge extends StatelessWidget {
  const OverlayBadge(this.text, {super.key, this.icon});
  final String text;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.75),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 14, color: Colors.white),
            const SizedBox(width: 4),
          ],
          Text(
            text,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

/// Video-site style card: thumbnail, then title and where it lives.
class FileCard extends StatelessWidget {
  const FileCard(this.file, {super.key, this.note});
  final FileView file;

  /// An extra line, such as why it matched a search.
  final String? note;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => openFile(context, file),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          FileThumbnail(file),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      file.displayTitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(fontSize: 15),
                    ),
                    const SizedBox(height: 4),
                    InkWell(
                      onTap: () => openCollection(context, file.collectionId),
                      child: Text(
                        file.collectionName,
                        style: muted,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Text(
                      '${kindLabel(kindForMime(file.mime))}  -  added ${timeAgo(file.addedAt)}',
                      style: muted,
                    ),
                    if (note != null)
                      Text(
                        note!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: muted?.copyWith(
                          color: theme.colorScheme.onSurface,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Playlist-style card for a collection.
class CollectionCard extends StatelessWidget {
  const CollectionCard(this.collection, {super.key, required this.circleName});
  final CollectionView collection;
  final String circleName;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final c = collection;
    // Only the picture the owner chose; otherwise a folder, so nobody
    // mistakes the collection for one of its files.
    final cover = c.coverFile;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => openCollection(context, c.id),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Stack(
            children: [
              if (cover != null)
                FileThumbnail(cover, badge: false, animateOnHover: false)
              else
                AspectRatio(
                  aspectRatio: 16 / 9,
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(colors: paletteFor(c.id)),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      Icons.folder_open,
                      size: 44,
                      color: Colors.white.withValues(alpha: 0.85),
                    ),
                  ),
                ),
              Positioned(
                right: 8,
                bottom: 8,
                child: OverlayBadge(
                  plural(c.files.length, 'file'),
                  icon: Icons.folder_copy_outlined,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            c.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleSmall?.copyWith(fontSize: 15),
          ),
          const SizedBox(height: 4),
          Text('$circleName  -  ${formatBytes(c.size)}', style: muted),
        ],
      ),
    );
  }
}

/// Asks for a collection's name and where it lives, then creates it.
/// Returns the new collection's id.
Future<String?> createCollectionFlow(BuildContext context) =>
    showDialog<String>(
      context: context,
      builder: (_) => const _NewCollectionDialog(),
    );

class _NewCollectionDialog extends StatefulWidget {
  const _NewCollectionDialog();

  @override
  State<_NewCollectionDialog> createState() => _NewCollectionDialogState();
}

class _NewCollectionDialogState extends State<_NewCollectionDialog> {
  final _name = TextEditingController();
  final _description = TextEditingController();
  String? _folder;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _name.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    super.dispose();
  }

  Future<void> _pickFolder() async {
    final path = await pickFolder();
    if (path != null && mounted) {
      setState(() {
        _folder = path;
        if (_name.text.trim().isEmpty) {
          _name.text = path
              .split(Platform.pathSeparator)
              .where((s) => s.isNotEmpty)
              .last;
        }
      });
    }
  }

  Future<void> _create() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final (error, id) = await Core.instance.createCollection(
      _name.text,
      _description.text,
      folder: _folder,
    );
    if (!mounted) return;
    if (error != null) {
      setState(() {
        _busy = false;
        _error = error;
      });
    } else {
      Navigator.pop(context, id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = Core.instance.state.value;
    final base =
        state?.storage.where((s) => s.isDefault).firstOrNull?.path ?? '';
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('New collection'),
      // Scrolls on small screens with large text instead of overflowing.
      scrollable: true,
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'It will be part of ${state?.commons.name ?? 'Arca Commons'}.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _name,
              autofocus: true,
              decoration: InputDecoration(
                labelText: 'Name',
                border: const OutlineInputBorder(),
                errorText: _error,
                errorMaxLines: 3,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _description,
              maxLines: 2,
              decoration: const InputDecoration(
                labelText: 'Description (optional)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            Text('Files', style: theme.textTheme.labelLarge),
            RadioGroup<bool>(
              groupValue: _folder == null,
              onChanged: (newFolder) =>
                  newFolder! ? setState(() => _folder = null) : _pickFolder(),
              child: Column(
                children: [
                  RadioListTile<bool>(
                    contentPadding: EdgeInsets.zero,
                    value: true,
                    title: const Text('Start empty, in a new folder'),
                    subtitle: Text(
                      '$base/${_name.text.isEmpty ? '...' : _name.text}',
                      style: const TextStyle(fontFamily: 'monospace'),
                    ),
                  ),
                  RadioListTile<bool>(
                    contentPadding: EdgeInsets.zero,
                    value: false,
                    title: const Text('Use a folder I already have'),
                    subtitle: Text(
                      _folder ?? 'Its files join the collection where they are',
                      style: _folder == null
                          ? null
                          : const TextStyle(fontFamily: 'monospace'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy ? null : _create,
          child: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Create'),
        ),
      ],
    );
  }
}
