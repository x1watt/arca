import 'package:flutter/material.dart';

import '../core/core_client.dart';
import '../core/pickers.dart';
import '../models/kinds.dart';
import '../widgets/common.dart';

/// Builds a query from a form: words and filters, a hash, or a file on disk.
/// Returns the query to run, or null if cancelled.
class AdvancedSearchScreen extends StatefulWidget {
  const AdvancedSearchScreen({super.key, this.initialQuery = ''});
  final String initialQuery;

  @override
  State<AdvancedSearchScreen> createState() => _AdvancedSearchScreenState();
}

class _AdvancedSearchScreenState extends State<AdvancedSearchScreen> {
  late final _allWords = TextEditingController(
    text: widget.initialQuery.toUpperCase().startsWith('SHA')
        ? ''
        : widget.initialQuery,
  );
  final _phrase = TextEditingController();
  final _exclude = TextEditingController();
  final _hash = TextEditingController();
  bool _sha1 = false;
  FileKind? _kind;
  String? _pickedFile;
  String? _pickedHash;
  bool _hashing = false;

  @override
  void dispose() {
    for (final c in [_allWords, _phrase, _exclude, _hash]) {
      c.dispose();
    }
    super.dispose();
  }

  void _searchText() {
    final parts = [
      _allWords.text.trim(),
      if (_phrase.text.trim().isNotEmpty) '"${_phrase.text.trim()}"',
      for (final w
          in _exclude.text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty))
        '-$w',
      if (_kind != null) 'type:${_kind!.name}',
    ].where((p) => p.isNotEmpty);
    Navigator.pop(context, parts.join(' '));
  }

  void _searchHash() {
    final value = _hash.text
        .trim()
        .replaceAll(RegExp(r'\s+'), '')
        .toLowerCase();
    if (value.isEmpty) return;
    Navigator.pop(context, '${_sha1 ? 'SHA1' : 'SHA256'}:$value');
  }

  Future<void> _pickFile() async {
    final path = await pickFile();
    if (path == null) return;
    setState(() {
      _pickedFile = path;
      _pickedHash = null;
      _hashing = true;
    });
    final h = await Core.instance.hashFile(path);
    if (!mounted) return;
    setState(() {
      _hashing = false;
      _pickedHash = h?.$1;
    });
    if (h == null) showMessage(context, 'Could not read that file');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Advanced search'),
          bottom: const TabBar(
            tabs: [
              Tab(icon: Icon(Icons.text_fields), text: 'Words and filters'),
              Tab(icon: Icon(Icons.tag), text: 'By hash'),
              Tab(icon: Icon(Icons.upload_file_outlined), text: 'By file'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _form([
              _field(_allWords, 'All of these words'),
              _field(_phrase, 'This exact phrase'),
              _field(_exclude, 'None of these words'),
              DropdownMenu<FileKind?>(
                label: const Text('Type'),
                expandedInsets: EdgeInsets.zero,
                initialSelection: _kind,
                onSelected: (k) => setState(() => _kind = k),
                dropdownMenuEntries: [
                  const DropdownMenuEntry(value: null, label: 'Any type'),
                  for (final k in FileKind.values)
                    DropdownMenuEntry(
                      value: k,
                      label: kindLabel(k),
                      leadingIcon: Icon(kindIcon(k)),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _searchText,
                icon: const Icon(Icons.search),
                label: const Text('Search'),
              ),
            ]),
            _form([
              Text(
                'Find a file by its hash. You can also type it straight into the search box, '
                'for example SHA1:00090922133...',
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 16),
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: false, label: Text('SHA-256')),
                  ButtonSegment(value: true, label: Text('SHA-1')),
                ],
                selected: {_sha1},
                onSelectionChanged: (s) => setState(() => _sha1 = s.first),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _hash,
                style: const TextStyle(fontFamily: 'monospace'),
                decoration: InputDecoration(
                  labelText: '${_sha1 ? 'SHA-1' : 'SHA-256'} value',
                  prefixText: '${_sha1 ? 'SHA1' : 'SHA256'}:',
                  border: const OutlineInputBorder(),
                  helperText: 'Exact match; the first characters of the hash are enough',
                ),
                onSubmitted: (_) => _searchHash(),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _searchHash,
                icon: const Icon(Icons.search),
                label: const Text('Search by hash'),
              ),
            ]),
            _form([
              Text(
                'Choose a file on this device to find copies of it. It is only hashed '
                'here; the file itself is never sent anywhere.',
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: _hashing ? null : _pickFile,
                icon: const Icon(Icons.folder_open),
                label: Text(_pickedFile ?? 'Choose a file'),
              ),
              if (_hashing)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: LinearProgressIndicator(),
                ),
              if (_pickedHash != null) ...[
                const SizedBox(height: 16),
                SelectableText(
                  'SHA-256  $_pickedHash',
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                  ),
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: () =>
                      Navigator.pop(context, 'SHA256:$_pickedHash'),
                  icon: const Icon(Icons.search),
                  label: const Text('Find exact copies'),
                ),
                const SizedBox(height: 8),
                Text(
                  'Similar-file matching (TLSH for bytes, PDQ for images) is designed but not built yet.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ]),
          ],
        ),
      ),
    );
  }

  Widget _form(List<Widget> children) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 720),
      child: ListView(padding: const EdgeInsets.all(16), children: children),
    ),
  );

  Widget _field(TextEditingController c, String label) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: TextField(
      controller: c,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
      ),
      onSubmitted: (_) => _searchText(),
    ),
  );
}
