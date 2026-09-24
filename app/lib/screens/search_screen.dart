import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/core_client.dart';
import '../models/kinds.dart';
import '../widgets/cards.dart';
import '../widgets/common.dart';
import '../widgets/profile_button.dart';
import 'advanced_search_screen.dart';

enum _Scope { all, files, collections, circles }

/// Home shows the library; results replace it once a search is run.
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  static final _homeRequests = ValueNotifier(0);

  /// Clears the search and shows the home page again.
  static void goHome() => _homeRequests.value++;

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _controller = SearchController();

  /// Searches run in this session, most recent first.
  final _history = <String>[];

  /// The submitted query; null means the home page is shown.
  String? _query;
  _Scope _scope = _Scope.all;
  FileKind? _kind;

  @override
  void initState() {
    super.initState();
    SearchScreen._homeRequests.addListener(_clear);
  }

  @override
  void dispose() {
    SearchScreen._homeRequests.removeListener(_clear);
    _controller.dispose();
    super.dispose();
  }

  void _run(String query) {
    final q = query.trim();
    if (q.isNotEmpty) {
      _history
        ..remove(q)
        ..insert(0, q);
    }
    _controller.text = q;
    setState(() {
      _query = q.isEmpty ? null : q;
      _scope = _Scope.all;
      _kind = null;
    });
  }

  void _clear() {
    _controller.clear();
    setState(() => _query = null);
  }

  Future<void> _openAdvanced() async {
    final query = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => AdvancedSearchScreen(initialQuery: _controller.text),
      ),
    );
    if (query != null && mounted) _run(query);
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: Core.instance.state,
      builder: (context, state, _) {
        final s = state ?? const CoreState([], null);
        return Scaffold(
          appBar: AppBar(
            titleSpacing: 16,
            title: _SearchField(
              controller: _controller,
              history: _history,
              completions: (text) => _completions(s, text),
              onSubmitted: _run,
              onClear: _clear,
              onAdvanced: _openAdvanced,
            ),
            actions: [
              Tooltip(
                message: 'Your library; other people\'s catalogs join when you follow circles',
                child: Padding(
                  padding: const EdgeInsets.only(left: 8, right: 16),
                  child: Row(
                    children: [
                      Icon(
                        Icons.storage_outlined,
                        size: 18,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        'Searching ${formatBytes(s.librarySize)}',
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ],
                  ),
                ),
              ),
              const ProfileButton(),
            ],
          ),
          body: _query == null ? _Home(state: s) : _results(s, _query!),
        );
      },
    );
  }

  static List<String> _completions(CoreState s, String text) {
    final q = text.toLowerCase();
    final seen = <String>{};
    final out = <String>[];
    void add(String v) {
      if (v.toLowerCase().contains(q) && seen.add(v.toLowerCase())) out.add(v);
    }

    for (final f in s.allFiles) {
      add(f.displayTitle);
      f.tags.forEach(add);
    }
    for (final c in s.collections) {
      add(c.name);
    }
    add(s.commons.name);
    return out.take(8).toList();
  }

  // Results

  static final _filterToken = RegExp(r'^(-|type:|circle:|lang:|date:)');

  List<String> _words(String query) => query
      .replaceAll('"', ' ')
      .toLowerCase()
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty && !_filterToken.hasMatch(w))
      .toList();

  bool _matches(List<String> words, String text) =>
      words.isEmpty || words.every(text.toLowerCase().contains);

  Widget _results(CoreState s, String query) {
    final upper = query.trim().toUpperCase();
    for (final (prefix, label) in [
      ('SHA256:', 'SHA-256'),
      ('SHA1:', 'SHA-1'),
    ]) {
      if (upper.startsWith(prefix)) {
        return _hashResults(
          s,
          label,
          query.trim().substring(prefix.length).toLowerCase(),
        );
      }
    }

    final words = _words(query);
    final files = s.allFiles
        .where((f) => _kind == null || kindForMime(f.mime) == _kind)
        .where(
          (f) => _matches(
            words,
            '${f.displayTitle} ${f.path} ${f.tags.join(' ')} ${f.description} ${f.collectionName}',
          ),
        )
        .toList();
    final collections = s.collections
        .where((c) => _matches(words, '${c.name} ${c.description}'))
        .toList();
    final circleMatches = _matches(
      words,
      '${s.commons.name} ${s.commons.description}',
    );
    final showKinds = _scope == _Scope.all || _scope == _Scope.files;
    final count = switch (_scope) {
      _Scope.all => files.length + collections.length,
      _Scope.files => files.length,
      _Scope.collections => collections.length,
      _Scope.circles => circleMatches ? 1 : 0,
    };

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: SizedBox(
            height: 52,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              children: [
                for (final (scope, label) in [
                  (_Scope.all, 'All'),
                  (_Scope.files, 'Files'),
                  (_Scope.collections, 'Collections'),
                  (_Scope.circles, 'Circles'),
                ])
                  _Pill(
                    label: label,
                    selected: _scope == scope,
                    onTap: () => setState(() => _scope = scope),
                  ),
                if (showKinds) ...[
                  const VerticalDivider(width: 20, indent: 6, endIndent: 6),
                  for (final (kind, label) in [
                    (FileKind.video, 'Videos'),
                    (FileKind.audio, 'Audio'),
                    (FileKind.book, 'Books'),
                    (FileKind.document, 'Documents'),
                    (FileKind.map, 'Maps'),
                    (FileKind.image, 'Images'),
                    (FileKind.dataset, 'Datasets'),
                  ])
                    _Pill(
                      label: label,
                      selected: _kind == kind,
                      onTap: () =>
                          setState(() => _kind = _kind == kind ? null : kind),
                    ),
                ],
              ],
            ),
          ),
        ),
        _note('${plural(count, 'result')} for "$query" in your library'),
        if (_scope == _Scope.all) ...[
          if (collections.isNotEmpty) ...[
            _header(context, 'Collections'),
            _row(
              height: 262,
              width: 300,
              children: [
                for (final c in collections)
                  CollectionCard(c, circleName: s.commons.name),
              ],
            ),
            _header(context, 'Files'),
          ],
          _grid(files.length, (i) => FileCard(files[i]), extraHeight: 96),
        ],
        if (_scope == _Scope.files)
          _grid(files.length, (i) => FileCard(files[i]), extraHeight: 96),
        if (_scope == _Scope.collections)
          _grid(
            collections.length,
            (i) => CollectionCard(collections[i], circleName: s.commons.name),
            extraHeight: 72,
          ),
        if (_scope == _Scope.circles)
          circleMatches
              ? SliverToBoxAdapter(child: _CommonsTile(s.commons))
              : _grid(0, (_) => const SizedBox.shrink()),
        const SliverToBoxAdapter(child: SizedBox(height: 32)),
      ],
    );
  }

  Widget _hashResults(CoreState s, String label, String prefix) {
    final valid = prefix.length >= 6 && RegExp(r'^[0-9a-f]+$').hasMatch(prefix);
    final files = valid
        ? s.allFiles
              .where(
                (f) =>
                    (label == 'SHA-1' ? f.sha1 : f.sha256).startsWith(prefix),
              )
              .toList()
        : <FileView>[];
    final theme = Theme.of(context);
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: Container(
            margin: const EdgeInsets.all(16),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainer,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                const Icon(Icons.fingerprint),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        valid
                            ? 'Exact matches by $label'
                            : 'Type at least 6 hex characters of the $label',
                        style: theme.textTheme.titleMedium,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        prefix,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontFamily: 'monospace',
                        ),
                      ),
                    ],
                  ),
                ),
                TextButton(
                  onPressed: _openAdvanced,
                  child: const Text('Refine'),
                ),
              ],
            ),
          ),
        ),
        _grid(
          files.length,
          (i) => FileCard(files[i], note: 'Identical file'),
          extraHeight: 112,
        ),
      ],
    );
  }

  Widget _note(String text) => SliverToBoxAdapter(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
      child: Text(text, style: Theme.of(context).textTheme.bodySmall),
    ),
  );
}

class _CommonsTile extends StatelessWidget {
  const _CommonsTile(this.commons);
  final CircleView commons;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      leading: const CircleAvatar(radius: 24, child: Icon(Icons.public)),
      title: Text(commons.name),
      subtitle: Text(commons.description),
      onTap: () => openCircle(context),
    );
  }
}

// Home: the library, or a welcome when it is empty.

class _Home extends StatelessWidget {
  const _Home({required this.state});
  final CoreState state;

  @override
  Widget build(BuildContext context) {
    if (state.collections.isEmpty) {
      return EmptyState(
        icon: Icons.inventory_2_outlined,
        title: 'Welcome to Arca',
        text:
            'You are in ${state.commons.name}, the open circle every Arca user starts in. '
            'Create a collection, add files to it, and it becomes part of the shared library.',
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
    final recent = [...state.allFiles]
      ..sort((a, b) => b.addedAt.compareTo(a.addedAt));
    return CustomScrollView(
      slivers: [
        _header(context, 'Your collections'),
        _row(
          height: 262,
          width: 300,
          children: [
            for (final c in state.collections)
              CollectionCard(c, circleName: state.commons.name),
          ],
        ),
        if (recent.isNotEmpty) ...[
          _header(context, 'Recently added'),
          _grid(
            math.min(recent.length, 24),
            (i) => FileCard(recent[i]),
            extraHeight: 96,
          ),
        ],
        const SliverToBoxAdapter(child: SizedBox(height: 32)),
      ],
    );
  }
}

// Shared layout pieces.

Widget _header(BuildContext context, String title) => SliverToBoxAdapter(
  child: Padding(
    padding: const EdgeInsets.fromLTRB(16, 20, 16, 12),
    child: Text(title, style: Theme.of(context).textTheme.titleLarge),
  ),
);

Widget _row({
  required double height,
  required double width,
  required List<Widget> children,
}) => SliverToBoxAdapter(
  child: SizedBox(
    height: height,
    child: ListView.separated(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      itemCount: children.length,
      separatorBuilder: (_, _) => const SizedBox(width: 16),
      itemBuilder: (_, i) => SizedBox(width: width, child: children[i]),
    ),
  ),
);

/// Responsive grid: as many columns as fit, cards keep a 16:9 thumbnail.
Widget _grid(
  int count,
  Widget Function(int) builder, {
  double maxWidth = 380,
  double extraHeight = 0,
}) {
  if (count == 0) {
    return const SliverToBoxAdapter(
      child: Padding(
        padding: EdgeInsets.all(48),
        child: Center(child: Text('Nothing found')),
      ),
    );
  }
  return SliverPadding(
    padding: const EdgeInsets.symmetric(horizontal: 16),
    sliver: SliverLayoutBuilder(
      builder: (context, constraints) {
        const gap = 16.0;
        final width = constraints.crossAxisExtent;
        final columns = math.max(1, (width / maxWidth).ceil());
        final itemWidth = (width - gap * (columns - 1)) / columns;
        return SliverGrid.builder(
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            crossAxisSpacing: gap,
            mainAxisSpacing: 24,
            mainAxisExtent: itemWidth * 9 / 16 + extraHeight,
          ),
          itemCount: count,
          itemBuilder: (_, i) => builder(i),
        );
      },
    ),
  );
}

/// Search bar that opens a panel with past searches and completions.
class _SearchField extends StatelessWidget {
  const _SearchField({
    required this.controller,
    required this.history,
    required this.completions,
    required this.onSubmitted,
    required this.onClear,
    required this.onAdvanced,
  });
  final SearchController controller;
  final List<String> history;
  final List<String> Function(String) completions;
  final void Function(String) onSubmitted;
  final VoidCallback onClear;
  final VoidCallback onAdvanced;

  void _submit(String query) {
    if (controller.isOpen) controller.closeView(query);
    onSubmitted(query);
  }

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 640),
      child: SizedBox(
        height: 44,
        child: SearchAnchor(
          searchController: controller,
          isFullScreen: false,
          shrinkWrap: true,
          viewHintText: 'Search',
          viewConstraints: const BoxConstraints(maxHeight: 440),
          viewOnSubmitted: _submit,
          builder: (context, controller) => SearchBar(
            controller: controller,
            elevation: const WidgetStatePropertyAll(0),
            hintText: 'Search',
            leading: const Icon(Icons.search),
            onTap: controller.openView,
            onChanged: (_) => controller.openView(),
            onSubmitted: _submit,
            trailing: [
              ListenableBuilder(
                listenable: controller,
                builder: (_, _) => controller.text.isEmpty
                    ? const SizedBox.shrink()
                    : IconButton(
                        tooltip: 'Clear',
                        icon: const Icon(Icons.close),
                        onPressed: onClear,
                      ),
              ),
              IconButton(
                tooltip: 'Advanced search',
                icon: const Icon(Icons.tune),
                onPressed: onAdvanced,
              ),
            ],
          ),
          suggestionsBuilder: (context, controller) {
            final text = controller.text.trim();
            final past = history.where(
              (h) =>
                  text.isEmpty || h.toLowerCase().contains(text.toLowerCase()),
            );
            final isHash = RegExp(
              r'^sha(1|256):',
              caseSensitive: false,
            ).hasMatch(text);
            return [
              if (isHash)
                ListTile(
                  leading: const Icon(Icons.fingerprint),
                  title: Text('Find the file with this hash: $text'),
                  onTap: () => _submit(text),
                ),
              for (final h in past)
                ListTile(
                  leading: const Icon(Icons.history),
                  title: Text(h),
                  trailing: IconButton(
                    tooltip: 'Remove from history',
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () {
                      history.remove(h);
                      controller.text = controller.text;
                    },
                  ),
                  onTap: () => _submit(h),
                ),
              if (text.isNotEmpty && !isHash)
                for (final s in completions(
                  text,
                ).where((s) => !history.contains(s)))
                  ListTile(
                    leading: const Icon(Icons.search),
                    title: Text(s),
                    trailing: IconButton(
                      tooltip: 'Fill in',
                      icon: const Icon(Icons.north_west, size: 18),
                      onPressed: () => controller.text = s,
                    ),
                    onTap: () => _submit(s),
                  ),
            ];
          },
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({
    required this.label,
    required this.selected,
    required this.onTap,
  });
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Material(
        color: selected ? scheme.onSurface : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Text(
              label,
              style: TextStyle(
                color: selected ? scheme.surface : scheme.onSurface,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
