// Other people's collections, read from their relays over I2P, and
// suggesting metadata changes to them, like editing a wiki page: the owner
// reviews and accepts or rejects each suggestion.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/core_client.dart';
import '../models/kinds.dart';
import '../widgets/cards.dart';
import '../widgets/common.dart';

/// The Following tab: people followed and their collections.
class FollowingTab extends StatelessWidget {
  const FollowingTab({super.key, required this.state});
  final CoreState state;

  @override
  Widget build(BuildContext context) {
    if (state.following.isEmpty) {
      return EmptyState(
        icon: Icons.person_add_alt,
        title: 'Not following anyone yet',
        text:
            'Ask someone for their Arca address (in their profile menu: Copy my Arca address) '
            'and follow them to see their collections and suggest improvements.',
        action: FilledButton.icon(
          onPressed: () => followDialog(context),
          icon: const Icon(Icons.person_add_alt),
          label: const Text('Follow someone'),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(0, 8, 0, 96),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              TextButton.icon(
                onPressed: () => followDialog(context),
                icon: const Icon(Icons.person_add_alt),
                label: const Text('Follow someone'),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: () async {
                  final e = await Core.instance.refreshFollows();
                  if (e != null && context.mounted) showMessage(context, e);
                },
                icon: const Icon(Icons.refresh),
                label: const Text('Refresh'),
              ),
            ],
          ),
        ),
        for (final f in state.following) _FollowSection(follow: f),
      ],
    );
  }
}

Future<void> followDialog(BuildContext context) async {
  final c = TextEditingController();
  final address = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Follow someone'),
      content: SizedBox(
        width: 520,
        child: TextField(
          controller: c,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Their Arca address',
            hintText: 'arca:npub1...@....b32.i2p',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, c.text),
          child: const Text('Follow'),
        ),
      ],
    ),
  );
  if (address == null || address.trim().isEmpty) return;
  final error = await Core.instance.follow(address);
  if (context.mounted) {
    showMessage(
      context,
      error ?? 'Following. Fetching their collections over I2P...',
    );
  }
}

class _FollowSection extends StatelessWidget {
  const _FollowSection({required this.follow});
  final FollowView follow;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final status = follow.refreshing
        ? 'Fetching over I2P...'
        : follow.error ??
              (follow.fetchedAt == null
                  ? 'Not fetched yet'
                  : 'Updated ${timeAgo(follow.fetchedAt!)}');
    return Card.outlined(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  child: Text(follow.displayName.substring(0, 1).toUpperCase()),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        follow.displayName,
                        style: theme.textTheme.titleMedium,
                      ),
                      Text(
                        status,
                        style: follow.error != null
                            ? muted?.copyWith(color: theme.colorScheme.error)
                            : muted,
                      ),
                    ],
                  ),
                ),
                if (follow.refreshing)
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                PopupMenuButton<String>(
                  onSelected: (_) => Core.instance.unfollow(follow.pubkey),
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'unfollow', child: Text('Unfollow')),
                  ],
                ),
              ],
            ),
            if (follow.collections.isEmpty && follow.fetchedAt != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text('No collections shared yet.', style: muted),
              ),
            for (final c in follow.collections)
              ListTile(
                contentPadding: const EdgeInsets.only(left: 4),
                leading: const Icon(Icons.folder_special_outlined),
                title: Text(c.name),
                subtitle: Text(
                  '${plural(c.files.length, 'file')}  -  ${formatBytes(c.size)}',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => RemoteCollectionScreen(
                      ownerPubkey: follow.pubkey,
                      collectionId: c.id,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Someone else's collection. Read-only; files can get suggestions.
class RemoteCollectionScreen extends StatelessWidget {
  const RemoteCollectionScreen({
    super.key,
    required this.ownerPubkey,
    required this.collectionId,
  });
  final String ownerPubkey;
  final String collectionId;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: Core.instance.state,
      builder: (context, state, _) {
        final owner = state?.follow(ownerPubkey);
        final c = owner?.collections
            .where((c) => c.id == collectionId)
            .firstOrNull;
        if (owner == null || c == null) {
          return Scaffold(
            appBar: AppBar(),
            body: const EmptyState(
              icon: Icons.folder_off_outlined,
              title: 'Not available',
              text: '',
            ),
          );
        }
        final files = [
          ...c.files,
        ]..sort((a, b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()));
        final theme = Theme.of(context);
        return Scaffold(
          appBar: AppBar(title: Text(c.name)),
          body: ListView(
            padding: const EdgeInsets.only(bottom: 32),
            children: [
              Card.filled(
                margin: const EdgeInsets.all(12),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          CircleBadge(state!.commons.name),
                          const SizedBox(width: 8),
                          Text(
                            'by ${owner.displayName}',
                            style: theme.textTheme.bodySmall,
                          ),
                        ],
                      ),
                      if (c.description.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text(c.description),
                      ],
                      const SizedBox(height: 8),
                      Text(
                        '${plural(c.files.length, 'file')}  -  ${formatBytes(c.size)}. Downloading arrives with the next version; '
                        'you can already suggest better titles, descriptions and tags.',
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ),
              for (final f in files)
                ListTile(
                  leading: KindAvatar(kindForMime(f.mime), size: 40),
                  title: Text(f.displayTitle),
                  subtitle: Text('${f.path}  -  ${formatBytes(f.size)}'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => RemoteFileScreen(
                        ownerPubkey: ownerPubkey,
                        collectionId: collectionId,
                        path: f.path,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class RemoteFileScreen extends StatelessWidget {
  const RemoteFileScreen({
    super.key,
    required this.ownerPubkey,
    required this.collectionId,
    required this.path,
  });
  final String ownerPubkey;
  final String collectionId;
  final String path;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: Core.instance.state,
      builder: (context, state, _) {
        final owner = state?.follow(ownerPubkey);
        final c = owner?.collections
            .where((c) => c.id == collectionId)
            .firstOrNull;
        final f = c?.files.where((f) => f.path == path).firstOrNull;
        if (owner == null || c == null || f == null) {
          return Scaffold(
            appBar: AppBar(),
            body: const EmptyState(
              icon: Icons.hide_source,
              title: 'Not available',
              text: '',
            ),
          );
        }
        final theme = Theme.of(context);
        Widget field(
          String label,
          String value, {
          bool mono = false,
        }) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 110,
                child: Text(
                  label,
                  style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
              Expanded(
                child: SelectableText(
                  value,
                  style: mono
                      ? const TextStyle(fontFamily: 'monospace', fontSize: 12)
                      : null,
                ),
              ),
            ],
          ),
        );
        return Scaffold(
          appBar: AppBar(title: Text(f.name, overflow: TextOverflow.ellipsis)),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                fullscreenDialog: true,
                builder: (_) =>
                    SuggestChangesScreen(owner: owner, collection: c, file: f),
              ),
            ),
            icon: const Icon(Icons.edit_note),
            label: const Text('Suggest changes'),
          ),
          body: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 900),
              child: ListView(
                padding: const EdgeInsets.only(bottom: 96),
                children: [
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: AspectRatio(
                      aspectRatio: 16 / 9,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: TypePlaceholder(
                          kind: kindForMime(f.mime),
                          seed: f.sha256,
                        ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Text(
                      f.displayTitle,
                      style: theme.textTheme.headlineSmall,
                    ),
                  ),
                  if (f.description.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
                      child: Text(f.description),
                    ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                    child: Text(
                      'In ${c.name} by ${owner.displayName}',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                  if (f.tags.isNotEmpty) ...[
                    const SectionTitle('Tags'),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (final t in f.tags) Chip(label: Text(t)),
                        ],
                      ),
                    ),
                  ],
                  const SectionTitle('Details'),
                  field(
                    'Type',
                    '${kindLabel(kindForMime(f.mime))}  (${f.mime})',
                  ),
                  field('Size', formatBytes(f.size)),
                  field('Path', f.path, mono: true),
                  field('SHA-256', f.sha256, mono: true),
                  ..._mySuggestionTiles(
                    state!,
                    owner,
                    ownerPubkey,
                    collectionId,
                    path,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Suggests a new title, description and tags for someone else's file. The
/// suggestion is a signed Nostr event sent to the owner's relay over I2P.
class SuggestChangesScreen extends StatefulWidget {
  const SuggestChangesScreen({
    super.key,
    required this.owner,
    required this.collection,
    required this.file,
  });
  final FollowView owner;
  final RemoteCollection collection;
  final RemoteFile file;

  @override
  State<SuggestChangesScreen> createState() => _SuggestChangesScreenState();
}

class _SuggestChangesScreenState extends State<SuggestChangesScreen> {
  late final _title = TextEditingController(text: widget.file.title);
  late final _description = TextEditingController(
    text: widget.file.description,
  );
  late final _tags = TextEditingController(text: widget.file.tags.join(', '));
  final _note = TextEditingController();
  bool _sending = false;

  @override
  void dispose() {
    for (final c in [_title, _description, _tags, _note]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _send() async {
    final tags = _tags.text
        .split(',')
        .map((t) => t.trim())
        .where((t) => t.isNotEmpty)
        .toList();
    final f = widget.file;
    final title = _title.text.trim() == f.title ? null : _title.text.trim();
    final description = _description.text.trim() == f.description
        ? null
        : _description.text.trim();
    final changedTags = tags.join(',') == f.tags.join(',') ? null : tags;
    if (title == null && description == null && changedTags == null) {
      showMessage(context, 'Nothing changed yet');
      return;
    }
    setState(() => _sending = true);
    final error = await Core.instance.propose(
      owner: widget.owner,
      collection: widget.collection,
      file: f,
      title: title,
      description: description,
      tags: changedTags,
      note: _note.text.trim(),
    );
    if (!mounted) return;
    setState(() => _sending = false);
    if (error != null) {
      showMessage(context, error);
    } else {
      showMessage(context, 'Sent to ${widget.owner.displayName} for approval');
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text('Suggest changes'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton(
              onPressed: _sending ? null : _send,
              child: _sending
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Send for approval'),
            ),
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                '${widget.owner.displayName} reviews your suggestion before it changes ${widget.file.name}. '
                'It is signed by your profile and delivered to their relay over I2P.',
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _title,
                decoration: const InputDecoration(
                  labelText: 'Title',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _description,
                maxLines: 5,
                decoration: const InputDecoration(
                  labelText: 'Description',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _tags,
                decoration: const InputDecoration(
                  labelText: 'Tags',
                  helperText: 'Separated by commas',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _note,
                maxLines: 2,
                inputFormatters: [LengthLimitingTextInputFormatter(500)],
                decoration: const InputDecoration(
                  labelText: 'Note to the owner (optional)',
                  helperText:
                      'Why this is better, or where the information comes from',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

List<Widget> _mySuggestionTiles(
  CoreState state,
  FollowView owner,
  String ownerPubkey,
  String collectionId,
  String path,
) {
  final mine = state.mySuggestions
      .where(
        (m) =>
            m.owner == ownerPubkey &&
            m.collectionId == collectionId &&
            m.path == path,
      )
      .toList();
  if (mine.isEmpty) return const [];
  return [
    const SectionTitle('Your suggestions'),
    for (final m in mine)
      ListTile(
        leading: Icon(switch (m.status) {
          'accepted' => Icons.check_circle_outline,
          'rejected' => Icons.cancel_outlined,
          _ => Icons.hourglass_empty,
        }),
        title: Text(switch (m.status) {
          'accepted' => 'Accepted by ${owner.displayName}',
          'rejected' => 'Not accepted by ${owner.displayName}',
          _ => 'Waiting for ${owner.displayName}',
        }),
        subtitle: Text(
          '${[if (m.changes['title'] != null) 'title', if (m.changes['description'] != null) 'description', if (m.changes['tags'] != null) 'tags'].join(', ')}  -  sent ${timeAgo(m.createdAt)}',
        ),
      ),
  ];
}
