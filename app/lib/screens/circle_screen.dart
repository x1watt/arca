import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/core_client.dart';
import '../widgets/cards.dart';
import '../widgets/common.dart';

/// A circle's page. Only Arca Commons exists for now.
class CircleScreen extends StatelessWidget {
  const CircleScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: Core.instance.state,
      builder: (context, state, _) {
        final s = state ?? const CoreState([], null);
        final files = s.allFiles;
        return DefaultTabController(
          length: 3,
          child: Scaffold(
            appBar: AppBar(
              title: Text(s.commons.name),
              bottom: TabBar(
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                tabs: [
                  Tab(text: 'Collections (${s.collections.length})'),
                  Tab(text: 'Files (${files.length})'),
                  const Tab(text: 'About'),
                ],
              ),
            ),
            body: TabBarView(
              children: [
                s.collections.isEmpty
                    ? const EmptyState(
                        icon: Icons.folder_copy_outlined,
                        title: 'No collections here yet',
                        text: 'Collections you create appear here. Other people\'s arrive with sharing over I2P.',
                      )
                    : _Grid(
                        count: s.collections.length,
                        extraHeight: 72,
                        builder: (i) => CollectionCard(
                          s.collections[i],
                          circleName: s.commons.name,
                        ),
                      ),
                files.isEmpty
                    ? const EmptyState(
                        icon: Icons.insert_drive_file_outlined,
                        title: 'No files yet',
                        text: '',
                      )
                    : _Grid(
                        count: files.length,
                        extraHeight: 96,
                        builder: (i) => FileCard(files[i]),
                      ),
                ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    Text(
                      s.commons.description,
                      style: Theme.of(context).textTheme.bodyLarge,
                    ),
                    const SizedBox(height: 16),
                    const ListTile(
                      leading: Icon(Icons.public),
                      title: Text(
                        'Open: anyone can join, publish and download',
                      ),
                    ),
                    const ListTile(
                      leading: Icon(Icons.person_off_outlined),
                      title: Text('No admin; it is built into Arca'),
                    ),
                    const ListTile(
                      leading: Icon(Icons.verified_user_outlined),
                      title: Text('You are a member'),
                      subtitle: Text('Every profile starts in this circle'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _Grid extends StatelessWidget {
  const _Grid({
    required this.count,
    required this.builder,
    this.extraHeight = 0,
  });
  final int count;
  final Widget Function(int) builder;
  final double extraHeight;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const gap = 16.0;
        final width = constraints.maxWidth - 32;
        final columns = math.max(1, (width / 380).ceil());
        final itemWidth = (width - gap * (columns - 1)) / columns;
        return GridView.builder(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
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
    );
  }
}
