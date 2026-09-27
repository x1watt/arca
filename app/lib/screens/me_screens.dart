// The profile menu's own pages: My circles, History, Liked and shared
// files, and Help. Everything here is the core's state, nothing typed in.

import 'package:flutter/material.dart';

import '../core/core_client.dart';
import '../models/kinds.dart';
import '../widgets/cards.dart';
import '../widgets/collab.dart' show askText;
import '../widgets/common.dart';
import 'wallet_screen.dart';

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

/// A file of this profile's library by its SHA-256, if it is still here.
FileView? _file(CoreState s, String sha256) =>
    s.allFiles.where((f) => f.sha256 == sha256).firstOrNull;

class CirclesScreen extends StatelessWidget {
  const CirclesScreen({super.key});

  Future<void> _create(BuildContext context, ChainView chain) async {
    final name = await askText(
      context,
      title: 'Create a circle',
      label: 'Name',
      hint: 'Radio archive',
    );
    if (name == null || name.isEmpty || !context.mounted) return;
    final id = name
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    await _run(
      context,
      Core.instance.chainCreateCircle(id.length < 3 ? '$id-circle' : id, name),
      'Created. It earns once its first anchor is on the chain, within a minute or so.',
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('My circles')),
      body: ValueListenableBuilder(
        valueListenable: Core.instance.state,
        builder: (context, state, _) {
          final s = state ?? const CoreState([], null);
          final theme = Theme.of(context);
          final muted = theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          );
          final chain = s.chain;
          return ListView(
            padding: const EdgeInsets.only(bottom: 32),
            children: [
              const SectionTitle('On this device'),
              ListTile(
                leading: const Icon(Icons.groups_outlined),
                title: Text(s.commons.name),
                subtitle: Text(
                  '${s.commons.description.isEmpty ? 'Every profile starts here.' : s.commons.description} '
                  '${plural(s.collections.length, 'collection')} of yours.',
                  style: muted,
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => openCircle(context),
              ),
              SectionTitle(
                'On the test network',
                trailing: chain == null || chain.light
                    ? null
                    : TextButton.icon(
                        onPressed: () => _create(context, chain),
                        icon: const Icon(Icons.add),
                        label: const Text('Create'),
                      ),
              ),
              if (chain == null)
                ListTile(
                  leading: const Icon(Icons.toll_outlined),
                  title: const Text('Not on the test network'),
                  subtitle: Text(
                    'Take part in it from the wallet.',
                    style: muted,
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const WalletScreen(),
                    ),
                  ),
                )
              else if (chain.light)
                ListTile(
                  leading: const Icon(Icons.phone_android_outlined),
                  title: Text(
                    chain.circleName.isEmpty
                        ? 'Arca Commons'
                        : chain.circleName,
                  ),
                  subtitle: Text(
                    'This device follows the chain lightly: circles are listed on devices that keep files.',
                    style: muted,
                  ),
                )
              else ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Text(
                    'Creating a circle burns ${formatMarcas(chain.circleFee)}. The files you keep earn for the '
                    'circle you keep them for.',
                    style: muted,
                  ),
                ),
                for (final c in chain.circles)
                  ExpansionTile(
                    leading: Icon(
                      c.keeping ? Icons.inventory_2 : Icons.groups_outlined,
                    ),
                    title: Text(c.name),
                    subtitle: Text(
                      [
                        'Pool ${formatMarcas(c.pool)}',
                        if (c.admin)
                          'you are its admin'
                        else if (c.moderator)
                          'you moderate it',
                        if (c.keeping) 'you keep files for it',
                        if (!c.live) 'not anchored in the last day, so it earns nothing now',
                      ].join(', '),
                      style: muted,
                    ),
                    children: [
                      ListTile(
                        dense: true,
                        title: Text(
                          '${plural(c.moderators, 'moderator')}. You have claimed ${formatMarcas(c.claimed)} from it.',
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            if (!c.keeping)
                              FilledButton.tonal(
                                onPressed: () => _run(
                                  context,
                                  Core.instance.chainKeepFor(c.id),
                                  'Your files now earn for ${c.name}.',
                                ),
                                child: const Text('Keep my files for it'),
                              ),
                            if (c.admin)
                              OutlinedButton(
                                onPressed: () => _run(
                                  context,
                                  Core.instance.chainPayout(c.id),
                                  'Paid out. Members can claim once the circle anchors it.',
                                ),
                                child: const Text('Pay out the pool'),
                              ),
                            OutlinedButton(
                              onPressed: () => _run(
                                context,
                                Core.instance.chainClaim(c.id),
                                'Claimed. It arrives with the next block.',
                              ),
                              child: const Text('Claim my share'),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
              ],
            ],
          );
        },
      ),
    );
  }
}

class HistoryScreen extends StatelessWidget {
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: Core.instance.state,
      builder: (context, state, _) {
        final s = state ?? const CoreState([], null);
        return Scaffold(
          appBar: AppBar(
            title: const Text('History'),
            actions: [
              if (s.opened.isNotEmpty)
                TextButton(
                  onPressed: () => _run(context, Core.instance.clearOpened()),
                  child: const Text('Clear'),
                ),
            ],
          ),
          body: s.opened.isEmpty
              ? const EmptyState(
                  icon: Icons.history,
                  title: 'Nothing opened yet',
                  text: 'Files you open appear here. The list stays on this device.',
                )
              : ListView(
                  children: [
                    for (final o in s.opened)
                      Builder(
                        builder: (context) {
                          final f = _file(s, o.sha256);
                          return ListTile(
                            leading: f == null
                                ? const Icon(Icons.insert_drive_file_outlined)
                                : KindAvatar(kindForMime(f.mime)),
                            title: Text(o.name),
                            subtitle: Text(
                              f == null
                                  ? 'Opened ${timeAgo(o.at)}; no longer on this device'
                                  : 'Opened ${timeAgo(o.at)}',
                            ),
                            enabled: f != null,
                            onTap: f == null
                                ? null
                                : () => openFile(context, f),
                          );
                        },
                      ),
                  ],
                ),
        );
      },
    );
  }
}

class LikedScreen extends StatelessWidget {
  const LikedScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: Core.instance.state,
      builder: (context, state, _) {
        final s = state ?? const CoreState([], null);
        final liked = s.liked.toList();
        return Scaffold(
          appBar: AppBar(title: const Text('Liked and shared files')),
          body: liked.isEmpty
              ? const EmptyState(
                  icon: Icons.thumb_up_outlined,
                  title: 'No liked files yet',
                  text:
                      'Like a file with the thumb on its page. A like is public: it tells others you value the '
                      'file and share it.',
                )
              : ListView(
                  children: [
                    for (final sha in liked)
                      Builder(
                        builder: (context) {
                          final f = _file(s, sha);
                          return ListTile(
                            leading: f == null
                                ? const Icon(Icons.insert_drive_file_outlined)
                                : KindAvatar(kindForMime(f.mime)),
                            title: Text(f?.name ?? 'A file not on this device'),
                            subtitle: Text(
                              f == null
                                  ? 'SHA-256 ${sha.substring(0, 16)}...'
                                  : f.collectionName,
                            ),
                            onTap: f == null
                                ? null
                                : () => openFile(context, f),
                            trailing: IconButton(
                              tooltip: 'Unlike',
                              icon: const Icon(Icons.thumb_up),
                              onPressed: () =>
                                  _run(context, Core.instance.like(sha, false)),
                            ),
                          );
                        },
                      ),
                  ],
                ),
        );
      },
    );
  }
}

class HelpScreen extends StatelessWidget {
  const HelpScreen({super.key});

  static const _topics = [
    (
      Icons.person_outline,
      'Profiles and addresses',
      'A profile is a key that says who you are, kept encrypted on this device. Its Arca address, '
          'arca:npub...@....b32.i2p, is how others reach you: copy it from the profile menu. Arca talks only '
          'over I2P, so nobody learns where you are. You can hold several profiles on one device; they do not '
          'reveal each other.',
    ),
    (
      Icons.folder_outlined,
      'Collections and copies',
      'A collection is a folder of files you share, with a title, a description and tags for each. Beside '
          'every file Arca keeps its manifest and subtitles under the same name, so you can copy them with any '
          'program. Follow someone by their address to see their collections, and keep a copy of one to have its '
          'files on this device, updated as it changes.',
    ),
    (
      Icons.edit_note,
      'Suggestions and moderators',
      'You can suggest better titles, descriptions and tags on others\' files; the owner or a moderator accepts '
          'or rejects them. An owner can make people moderators of a collection: they then change it directly.',
    ),
    (
      Icons.toll_outlined,
      'The test network and marcas',
      'Marcas pay people for keeping files safe. On the test network, which is built into Arca and found over I2P '
          'without any address to type, devices keep copies of its files, prove every day that they still hold '
          'them, and earn for their circle. '
          'The circle\'s admin pays out its pool; members claim their share, which is public. Payments between '
          'people are private: nobody sees how much, who paid or who was paid. Move marcas from your public '
          'balance to the private side in the wallet, and give people your wallet address (marca1...). An '
          'auditor you trust can be given a view key: it shows what you received and spent, and cannot spend. '
          'Test marcas have no value. Phones follow lightly by default and keep nothing, so they cost little '
          'battery.',
    ),
    (
      Icons.tune,
      'Sharing limits',
      'Settings, Sharing decides when this device serves others and does heavy work: only on Wi-Fi or a cable, '
          'only while charging, during chosen hours, and how fast it uploads. These limits never leave the device.',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).textTheme.bodyMedium
        ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant);
    return Scaffold(
      appBar: AppBar(title: const Text('Help')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          for (final (icon, title, text) in _topics)
            ExpansionTile(
              leading: Icon(icon),
              title: Text(title),
              childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              children: [Text(text, style: muted)],
            ),
        ],
      ),
    );
  }
}
