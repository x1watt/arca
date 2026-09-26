// Working on collections together: keeping a copy of someone else's
// collection, the admin's list of moderators, and the small dialogs a
// moderator uses to change files directly.

import 'package:arca_core/arca_core.dart' show npubEncode, fromHex;
import 'package:flutter/material.dart';

import '../core/core_client.dart';
import 'common.dart';

Future<void> _run(
  BuildContext context,
  Future<String?> action, [
  String? done,
]) async {
  final error = await action;
  if (!context.mounted) return;
  if (error != null) {
    showMessage(context, error);
  } else if (done != null) {
    showMessage(context, done);
  }
}

String _npub(String pubkey) => npubEncode(fromHex(pubkey));

String shortKey(String pubkey) {
  final n = _npub(pubkey);
  return '${n.substring(0, 12)}...${n.substring(n.length - 4)}';
}

String _arcaAddress(ModeratorView m) => 'arca:${_npub(m.pubkey)}@${m.address}';

/// Asks for one line of text; null when cancelled.
Future<String?> askText(
  BuildContext context, {
  required String title,
  required String label,
  String? hint,
}) => showDialog<String>(
  context: context,
  builder: (_) => _TextAsk(title: title, label: label, hint: hint),
);

class _TextAsk extends StatefulWidget {
  const _TextAsk({required this.title, required this.label, this.hint});
  final String title;
  final String label;
  final String? hint;

  @override
  State<_TextAsk> createState() => _TextAskState();
}

class _TextAskState extends State<_TextAsk> {
  final _text = TextEditingController();

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    scrollable: true,
    content: TextField(
      controller: _text,
      autofocus: true,
      decoration: InputDecoration(
        labelText: widget.label,
        hintText: widget.hint,
      ),
      onSubmitted: (v) => Navigator.pop(context, v.trim()),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, _text.text.trim()),
        child: const Text('OK'),
      ),
    ],
  );
}

/// Edits a file's title, description and tags; returns only what changed,
/// or null when cancelled.
Future<Map<String, Object?>?> editDetails(BuildContext context, RemoteFile f) =>
    showDialog<Map<String, Object?>>(
      context: context,
      builder: (_) => _DetailsDialog(f),
    );

class _DetailsDialog extends StatefulWidget {
  const _DetailsDialog(this.file);
  final RemoteFile file;

  @override
  State<_DetailsDialog> createState() => _DetailsDialogState();
}

class _DetailsDialogState extends State<_DetailsDialog> {
  late final _title = TextEditingController(text: widget.file.title);
  late final _description = TextEditingController(
    text: widget.file.description,
  );
  late final _tags = TextEditingController(text: widget.file.tags.join(', '));

  @override
  void dispose() {
    _title.dispose();
    _description.dispose();
    _tags.dispose();
    super.dispose();
  }

  Map<String, Object?> _changes() {
    final f = widget.file;
    final tags = [
      for (final t in _tags.text.split(','))
        if (t.trim().isNotEmpty) t.trim(),
    ];
    return {
      if (_title.text.trim() != f.title) 'title': _title.text.trim(),
      if (_description.text.trim() != f.description)
        'description': _description.text.trim(),
      if (tags.join(',') != f.tags.join(',')) 'tags': tags,
    };
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('Edit ${widget.file.name}'),
    scrollable: true,
    content: SizedBox(
      width: 480,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _title,
            decoration: const InputDecoration(labelText: 'Title'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _description,
            minLines: 2,
            maxLines: 5,
            decoration: const InputDecoration(labelText: 'Description'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _tags,
            decoration: const InputDecoration(
              labelText: 'Tags, separated by commas',
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
        onPressed: () => Navigator.pop(context, _changes()),
        child: const Text('Save'),
      ),
    ],
  );
}

/// Keeping a copy of someone else's collection on this device.
class SyncCard extends StatelessWidget {
  const SyncCard({super.key, required this.owner, required this.collection});
  final FollowView owner;
  final RemoteCollection collection;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final s = collection.sync;
    final core = Core.instance;
    if (s == null) {
      return ListTile(
        leading: const Icon(Icons.download_for_offline_outlined),
        title: const Text('Keep a copy'),
        subtitle: Text(
          collection.complete
              ? 'Copies the files to this device and keeps them up to date as the collection changes.'
              : 'This collection is too large to copy yet.',
          style: muted,
        ),
        trailing: FilledButton.tonal(
          onPressed: collection.complete
              ? () => _run(context, core.sync(owner.pubkey, collection.id))
              : null,
          child: const Text('Keep a copy'),
        ),
      );
    }
    final progress = s.totalBytes == 0 ? null : s.bytes / s.totalBytes;
    final status = s.running
        ? 'Copying: ${s.done} of ${plural(s.total, 'file')}, ${formatBytes(s.bytes)} of ${formatBytes(s.totalBytes)}'
        : s.error != null
        ? 'Not complete: ${s.error}'
        : 'Up to date: ${plural(s.done, 'file')}, ${formatBytes(s.totalBytes)}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          leading: Icon(
            s.running ? Icons.downloading_outlined : Icons.offline_pin_outlined,
            color: s.error != null && !s.running
                ? theme.colorScheme.error
                : null,
          ),
          title: const Text('A copy is kept on this device'),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(status, style: muted),
              if (s.running)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: LinearProgressIndicator(value: progress),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Wrap(
            spacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: () => openWithSystem(context, s.folder),
                icon: const Icon(Icons.folder_open_outlined),
                label: const Text('Open folder'),
              ),
              TextButton(
                onPressed: () => _run(
                  context,
                  core.sync(owner.pubkey, collection.id, on: false),
                  'No longer kept up to date; the files already copied stay.',
                ),
                child: const Text('Stop keeping a copy'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// The admin's list of moderators for one of its collections.
class ModeratorsSection extends StatelessWidget {
  const ModeratorsSection({super.key, required this.collection});
  final CollectionView collection;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final core = Core.instance;
    final mods = collection.moderators;
    Future<void> add() async {
      final address = await askText(
        context,
        title: 'Add a moderator',
        label: 'Their Arca address',
        hint: 'arca:npub1...@....b32.i2p',
      );
      if (address == null || address.isEmpty || !context.mounted) return;
      await _run(
        context,
        core.setModerators(collection.id, [
          for (final m in mods) _arcaAddress(m),
          address,
        ]),
        'Moderator added',
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionTitle(
          'Moderators',
          trailing: TextButton.icon(
            onPressed: add,
            icon: const Icon(Icons.person_add_alt_outlined),
            label: const Text('Add'),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
          child: Text(
            mods.isEmpty
                ? 'Only you can change this collection. Moderators can add, remove and edit files, '
                      'and accept or reject suggestions.'
                : 'Besides you, they can add, remove and edit files, and accept or reject suggestions.',
            style: muted,
          ),
        ),
        for (final m in mods)
          ListTile(
            leading: const Icon(Icons.shield_outlined),
            title: Text(shortKey(m.pubkey)),
            subtitle: Text(
              m.address,
              style: muted,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: IconButton(
              tooltip: 'Remove moderator',
              icon: const Icon(Icons.person_remove_outlined),
              onPressed: () => _run(
                context,
                core.setModerators(collection.id, [
                  for (final x in mods)
                    if (x.pubkey != m.pubkey) _arcaAddress(x),
                ]),
                'Moderator removed',
              ),
            ),
          ),
      ],
    );
  }
}
