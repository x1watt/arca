import 'package:flutter/material.dart';

import '../core/core_client.dart';
import '../widgets/common.dart';

/// What a suggestion is compared with: the file as the collection lists it.
typedef CurrentFile = ({
  String name,
  String title,
  String description,
  List<String> tags,
});

/// Suggestions others sent for files in a collection this profile
/// administers or moderates.
class ReviewScreen extends StatelessWidget {
  const ReviewScreen({super.key, required this.collectionId});
  final String collectionId;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: Core.instance.state,
      builder: (context, state, _) {
        final col = state?.collection(collectionId);
        final pending =
            state?.proposalsFor(collectionId) ?? const <ProposalView>[];
        // Moderating someone else's collection: its files as followed.
        final remote = col != null
            ? null
            : state?.following
                  .expand((f) => f.collections)
                  .where((c) => c.id == collectionId)
                  .firstOrNull;
        CurrentFile? current(String path) {
          final own = col?.files.where((f) => f.path == path).firstOrNull;
          if (own != null) {
            return (
              name: own.name,
              title: own.title,
              description: own.description,
              tags: own.tags,
            );
          }
          final r = remote?.files.where((f) => f.path == path).firstOrNull;
          return r == null
              ? null
              : (
                  name: r.name,
                  title: r.title,
                  description: r.description,
                  tags: r.tags,
                );
        }

        return Scaffold(
          appBar: AppBar(
            title: Text('Suggestions for ${col?.name ?? remote?.name ?? ''}'),
          ),
          body: pending.isEmpty
              ? const EmptyState(
                  icon: Icons.task_alt,
                  title: 'Nothing to review',
                  text: 'New suggestions appear here.',
                )
              : ListView(
                  padding: const EdgeInsets.all(12),
                  children: [
                    for (final p in pending)
                      _ProposalCard(proposal: p, current: current(p.path)),
                  ],
                ),
        );
      },
    );
  }
}

class _ProposalCard extends StatefulWidget {
  const _ProposalCard({required this.proposal, required this.current});
  final ProposalView proposal;
  final CurrentFile? current;

  @override
  State<_ProposalCard> createState() => _ProposalCardState();
}

class _ProposalCardState extends State<_ProposalCard> {
  bool _busy = false;

  Future<void> _decide(bool accept) async {
    setState(() => _busy = true);
    final error = await Core.instance.decide(
      widget.proposal.id,
      accept: accept,
    );
    if (!mounted) return;
    setState(() => _busy = false);
    showMessage(
      context,
      error ?? (accept ? 'Accepted and published' : 'Rejected'),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = widget.proposal;
    final f = widget.current;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    Widget change(String label, String before, String after) => Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: theme.textTheme.labelLarge),
          const SizedBox(height: 4),
          Text(
            before.isEmpty ? '(empty)' : before,
            style: muted?.copyWith(decoration: TextDecoration.lineThrough),
          ),
          const SizedBox(height: 2),
          Text(after.isEmpty ? '(empty)' : after),
        ],
      ),
    );
    return Card.outlined(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.edit_note),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    f?.name ?? p.path,
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                Text(timeAgo(p.createdAt), style: muted),
              ],
            ),
            Text('Suggested by ${p.from}', style: muted),
            if (f == null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'This file is no longer in the collection.',
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ),
            if (p.changes['title'] != null)
              change('Title', f?.title ?? '', p.changes['title'] as String),
            if (p.changes['description'] != null)
              change(
                'Description',
                f?.description ?? '',
                p.changes['description'] as String,
              ),
            if (p.changes['tags'] != null)
              change(
                'Tags',
                f?.tags.join(', ') ?? '',
                (p.changes['tags'] as List).join(', '),
              ),
            if (p.note.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                'Note: ${p.note}',
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontStyle: FontStyle.italic,
                ),
              ),
            ],
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: _busy ? null : () => _decide(false),
                  child: const Text('Reject'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _busy || f == null ? null : () => _decide(true),
                  child: const Text('Accept'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
