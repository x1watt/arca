import 'package:flutter/material.dart';

import '../core/core_client.dart';
import '../widgets/cards.dart';
import '../widgets/common.dart';
import '../widgets/profile_button.dart';
import 'following_screens.dart';

class CollectionsScreen extends StatelessWidget {
  const CollectionsScreen({super.key});

  Future<void> _create(BuildContext context) async {
    final id = await createCollectionFlow(context);
    if (id != null && context.mounted) openCollection(context, id);
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Collections'),
          actions: const [ProfileButton()],
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Following'),
              Tab(text: 'Mine'),
            ],
          ),
        ),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: () => _create(context),
          icon: const Icon(Icons.create_new_folder_outlined),
          label: const Text('New collection'),
        ),
        body: ValueListenableBuilder(
          valueListenable: Core.instance.state,
          builder: (context, state, _) {
            final s = state ?? const CoreState([], null);
            return TabBarView(
              children: [
                FollowingTab(state: s),
                s.collections.isEmpty
                    ? EmptyState(
                        icon: Icons.folder_copy_outlined,
                        title: 'No collections yet',
                        text:
                            'A collection is a folder of files you keep and share. '
                            'Create one, or turn a folder you already have into one.',
                        action: FilledButton.icon(
                          onPressed: () => _create(context),
                          icon: const Icon(Icons.create_new_folder_outlined),
                          label: const Text('New collection'),
                        ),
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
                        itemCount: s.collections.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 8),
                        itemBuilder: (context, i) => _CollectionTile(
                          s.collections[i],
                          s.commons.name,
                          s.proposalsFor(s.collections[i].id).length,
                        ),
                      ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _CollectionTile extends StatelessWidget {
  const _CollectionTile(this.c, this.circleName, this.suggestions);
  final CollectionView c;
  final String circleName;
  final int suggestions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Card.outlined(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => openCollection(context, c.id),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.folder_special_outlined,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(c.name, style: theme.textTheme.titleMedium),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      border: Border.all(color: theme.colorScheme.primary),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text('Admin', style: theme.textTheme.labelSmall),
                  ),
                ],
              ),
              if (c.description.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  c.description,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  CircleBadge(circleName),
                  if (suggestions > 0)
                    Chip(
                      visualDensity: VisualDensity.compact,
                      avatar: const Icon(Icons.rate_review_outlined, size: 16),
                      label: Text(
                        '${plural(suggestions, "suggestion")} to review',
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                '${plural(c.files.length, 'file')}  -  ${formatBytes(c.size)}',
                style: muted,
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  Icon(Icons.folder_outlined, size: 14, color: muted?.color),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      c.folder,
                      overflow: TextOverflow.ellipsis,
                      style: muted?.copyWith(fontFamily: 'monospace'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
