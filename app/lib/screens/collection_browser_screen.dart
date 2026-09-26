import 'package:flutter/material.dart';

import '../core/core_client.dart';
import '../core/pickers.dart';
import '../models/kinds.dart';
import '../widgets/cards.dart';
import '../widgets/comments.dart';
import '../widgets/collab.dart';
import '../widgets/common.dart';
import 'file_detail_screen.dart';
import 'review_screen.dart';

/// Browses a collection's folders and files. [path] is the folder inside the
/// collection, empty for its root.
class CollectionBrowserScreen extends StatelessWidget {
  const CollectionBrowserScreen({
    super.key,
    required this.collectionId,
    this.path = '',
  });

  final String collectionId;
  final String path;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: Core.instance.state,
      builder: (context, state, _) {
        final c = state?.collection(collectionId);
        if (c == null) {
          return Scaffold(
            appBar: AppBar(),
            body: const EmptyState(
              icon: Icons.folder_off_outlined,
              title: 'Collection not found',
              text: '',
            ),
          );
        }
        return _Browser(
          collection: c,
          path: path,
          circleName: state!.commons.name,
          ownerPubkey: state.active?.pubkey ?? '',
          suggestions: state.proposalsFor(c.id).length,
        );
      },
    );
  }
}

class _Browser extends StatefulWidget {
  const _Browser({
    required this.collection,
    required this.path,
    required this.circleName,
    required this.ownerPubkey,
    this.suggestions = 0,
  });
  final CollectionView collection;
  final String path;
  final String circleName;
  final String ownerPubkey;
  final int suggestions;

  @override
  State<_Browser> createState() => _BrowserState();
}

class _BrowserState extends State<_Browser> {
  bool _busy = false;

  CollectionView get c => widget.collection;

  Future<void> _add(Future<List<String>> Function() pick) async {
    final paths = await pick();
    if (paths.isEmpty) return;
    setState(() => _busy = true);
    final error = await Core.instance.addFiles(c.id, paths);
    if (!mounted) return;
    setState(() => _busy = false);
    showMessage(context, error ?? 'Added and described');
  }

  void _showAddSheet() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.upload_file_outlined),
              title: const Text('Add files'),
              subtitle: const Text(
                'They are copied into the collection folder',
              ),
              onTap: () {
                Navigator.pop(sheet);
                _add(pickFiles);
              },
            ),
            ListTile(
              leading: const Icon(Icons.create_new_folder_outlined),
              title: const Text('Add a folder with its files'),
              onTap: () {
                Navigator.pop(sheet);
                _add(() async {
                  final p = await pickFolder(title: 'Add');
                  return p == null ? <String>[] : [p];
                });
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _editCollection() async {
    final result = await showDialog<(String, String)>(
      context: context,
      builder: (_) =>
          _EditCollectionDialog(name: c.name, description: c.description),
    );
    if (result == null) return;
    final error = await Core.instance.updateCollection(
      c.id,
      name: result.$1,
      description: result.$2,
    );
    if (error != null && mounted) showMessage(context, error);
  }

  Future<void> _stopTracking() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove ${c.name}?'),
        content: const SizedBox(
          width: 440,
          child: Text(
            'Arca stops keeping and sharing this collection. The folder and its files stay on your disk.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await Core.instance.removeCollection(c.id);
    if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
  }

  Future<void> _fileMenu(FileView f, String action) async {
    switch (action) {
      case 'open':
        await openWithSystem(context, f.absolutePath);
      case 'edit':
        await openMetadataEditor(context, f);
      case 'cover':
      case 'uncover':
        final error = await Core.instance.setCover(
          f.collectionId,
          action == 'cover' ? f.path : null,
        );
        if (mounted && error != null) showMessage(context, error);
      case 'remove':
      case 'delete':
        final delete = action == 'delete';
        final ok = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(
              delete
                  ? 'Delete ${f.name}?'
                  : 'Remove ${f.name} from the collection?',
            ),
            content: Text(
              delete
                  ? 'The file is deleted from your disk.'
                  : 'The file stays on your disk.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(delete ? 'Delete' : 'Remove'),
              ),
            ],
          ),
        );
        if (ok == true) {
          await Core.instance.removeFile(f, deleteFromDisk: delete);
        }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final prefix = widget.path.isEmpty ? '' : '${widget.path}/';
    final here = c.files.where((f) => f.path.startsWith(prefix)).toList();
    final folders = <String, int>{};
    final files = <FileView>[];
    for (final f in here) {
      final rest = f.path.substring(prefix.length);
      if (rest.contains('/')) {
        final name = rest.substring(0, rest.indexOf('/'));
        folders[name] = (folders[name] ?? 0) + 1;
      } else {
        files.add(f);
      }
    }
    final sortedFolders = folders.keys.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    files.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    final isRoot = widget.path.isEmpty;

    return Scaffold(
      appBar: AppBar(
        title: Text(isRoot ? c.name : widget.path.split('/').last),
        actions: [
          IconButton(
            tooltip: 'Open the folder',
            icon: const Icon(Icons.folder_open_outlined),
            onPressed: () => openWithSystem(
              context,
              isRoot ? c.folder : '${c.folder}/${widget.path}',
            ),
          ),
          PopupMenuButton<String>(
            onSelected: (v) =>
                v == 'edit' ? _editCollection() : _stopTracking(),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'edit', child: Text('Rename or describe')),
              PopupMenuItem(value: 'remove', child: Text('Remove collection')),
            ],
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _busy ? null : _showAddSheet,
        icon: _busy
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.add),
        label: Text(_busy ? 'Adding...' : 'Add'),
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 96),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text(
              [
                c.name,
                ...widget.path.split('/').where((s) => s.isNotEmpty),
              ].join('  /  '),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          if (isRoot) _Header(collection: c, circleName: widget.circleName),
          if (isRoot && widget.suggestions > 0)
            Card.filled(
              margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: ListTile(
                leading: const Icon(Icons.rate_review_outlined),
                title: Text(
                  '${plural(widget.suggestions, "suggestion")} from others to review',
                ),
                subtitle: const Text(
                  'Accept to update your file and republish the collection',
                ),
                trailing: FilledButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => ReviewScreen(collectionId: c.id),
                    ),
                  ),
                  child: const Text('Review'),
                ),
              ),
            ),
          if (here.isEmpty)
            const Padding(
              padding: EdgeInsets.all(32),
              child: Center(
                child: Text(
                  'No files yet. Use Add to put files or folders in this collection.',
                ),
              ),
            ),
          for (final name in sortedFolders)
            ListTile(
              leading: Icon(
                Icons.folder_outlined,
                color: theme.colorScheme.primary,
              ),
              title: Text(name),
              subtitle: Text(plural(folders[name]!, 'file')),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => CollectionBrowserScreen(
                    collectionId: c.id,
                    path: '$prefix$name',
                  ),
                ),
              ),
            ),
          for (final f in files)
            ListTile(
              leading: KindAvatar(kindForMime(f.mime), size: 40),
              title: Text(f.displayTitle),
              subtitle: Text('${f.name}  -  ${formatBytes(f.size)}'),
              onTap: () => openFile(context, f),
              trailing: PopupMenuButton<String>(
                onSelected: (v) => _fileMenu(f, v),
                itemBuilder: (_) => [
                  const PopupMenuItem(value: 'open', child: Text('Open')),
                  const PopupMenuItem(
                    value: 'edit',
                    child: Text('Edit details'),
                  ),
                  if (c.cover == f.path)
                    const PopupMenuItem(
                      value: 'uncover',
                      child: Text('Stop using as collection picture'),
                    )
                  else
                    const PopupMenuItem(
                      value: 'cover',
                      child: Text('Use as collection picture'),
                    ),
                  const PopupMenuItem(
                    value: 'remove',
                    child: Text('Remove from collection'),
                  ),
                  const PopupMenuItem(
                    value: 'delete',
                    child: Text('Delete from disk'),
                  ),
                ],
              ),
            ),
          if (isRoot) ...[
            const Divider(height: 32),
            ModeratorsSection(collection: c),
            const Divider(height: 32),
            CommentsSection(
              target: 'arca:collection:${widget.ownerPubkey}:${c.id}',
            ),
          ],
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.collection, required this.circleName});
  final CollectionView collection;
  final String circleName;

  @override
  Widget build(BuildContext context) {
    final c = collection;
    final theme = Theme.of(context);
    Widget stat(String label, String value) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        Text(value, style: theme.textTheme.titleSmall),
      ],
    );
    return Card.filled(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            InkWell(
              onTap: () => openCircle(context),
              child: CircleBadge(circleName),
            ),
            if (c.description.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(c.description),
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 24,
              runSpacing: 8,
              children: [
                stat('Files', '${c.files.length}'),
                stat('Size', formatBytes(c.size)),
                stat('Created', timeAgo(c.createdAt)),
                stat('Your role', 'Admin'),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Icon(
                  Icons.folder_outlined,
                  size: 16,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: SelectableText(
                    c.folder,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _EditCollectionDialog extends StatefulWidget {
  const _EditCollectionDialog({required this.name, required this.description});
  final String name;
  final String description;

  @override
  State<_EditCollectionDialog> createState() => _EditCollectionDialogState();
}

class _EditCollectionDialogState extends State<_EditCollectionDialog> {
  late final _name = TextEditingController(text: widget.name);
  late final _description = TextEditingController(text: widget.description);

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Collection'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _name,
              decoration: const InputDecoration(
                labelText: 'Name',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _description,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'Description',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () =>
              Navigator.pop(context, (_name.text, _description.text)),
          child: const Text('Save'),
        ),
      ],
    );
  }
}
