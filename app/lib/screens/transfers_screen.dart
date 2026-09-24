import 'package:flutter/material.dart';

import '../core/core_client.dart';
import '../widgets/cards.dart';
import '../widgets/common.dart';
import '../widgets/profile_button.dart';

class TransfersScreen extends StatelessWidget {
  const TransfersScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Transfers'),
          actions: const [ProfileButton()],
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Downloads'),
              Tab(text: 'Updates'),
              Tab(text: 'Sharing'),
            ],
          ),
        ),
        body: ValueListenableBuilder(
          valueListenable: Core.instance.state,
          builder: (context, state, _) {
            final s = state ?? const CoreState([], null);
            return TabBarView(
              children: [
                const EmptyState(
                  icon: Icons.download_outlined,
                  title: 'No downloads',
                  text:
                      'Files you download from other people will appear here.',
                ),
                const EmptyState(
                  icon: Icons.sync,
                  title: 'Nothing to update',
                  text: 'When collections you follow gain new files, they will be listed here with their size.',
                ),
                _Sharing(state: s),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _Sharing extends StatelessWidget {
  const _Sharing({required this.state});
  final CoreState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    if (state.collections.isEmpty) {
      return EmptyState(
        icon: Icons.share_outlined,
        title: 'Nothing shared yet',
        text: 'Collections you create are shared in ${state.commons.name}.',
        action: FilledButton.icon(
          onPressed: () async {
            final id = await createCollectionFlow(context);
            if (id != null && context.mounted) openCollection(context, id);
          },
          icon: const Icon(Icons.create_new_folder_outlined),
          label: const Text('Create a collection'),
        ),
      );
    }
    final online = state.active?.online == true && state.net == NetStatus.up;
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
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
                    Icon(
                      Icons.circle,
                      size: 10,
                      color: online
                          ? const Color(0xFF4CAF50)
                          : theme.colorScheme.outline,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      online
                          ? 'Your profile is online on I2P'
                          : 'Your profile is not online',
                      style: theme.textTheme.titleSmall,
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  '${plural(state.collections.length, 'collection')}, ${plural(state.allFiles.length, 'file')}, '
                  '${formatBytes(state.librarySize)}. Their descriptions are published in your relay; '
                  'other people downloading the files themselves arrives with the next version.',
                  style: muted,
                ),
              ],
            ),
          ),
        ),
        const SectionTitle('Collections you share'),
        for (final c in state.collections)
          ListTile(
            leading: const Icon(Icons.folder_special_outlined),
            title: Text(c.name),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${plural(c.files.length, 'file')}  -  ${formatBytes(c.size)}',
                  style: muted,
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text('Shared in', style: muted),
                    CircleBadge(state.commons.name),
                  ],
                ),
              ],
            ),
            isThreeLine: true,
            onTap: () => openCollection(context, c.id),
          ),
      ],
    );
  }
}
