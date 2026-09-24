import 'package:flutter/material.dart';

import '../core/core_client.dart';
import '../widgets/common.dart';

/// Edits the details people see for a file: title, description and tags.
/// Saving updates the collection and republishes its Nostr event.
class MetadataEditorScreen extends StatefulWidget {
  const MetadataEditorScreen({super.key, required this.file});
  final FileView file;

  @override
  State<MetadataEditorScreen> createState() => _MetadataEditorScreenState();
}

class _MetadataEditorScreenState extends State<MetadataEditorScreen> {
  late final _title = TextEditingController(text: widget.file.title);
  late final _description = TextEditingController(
    text: widget.file.description,
  );
  final _newTag = TextEditingController();
  late final List<String> _tags = [...widget.file.tags];
  bool _saving = false;

  @override
  void dispose() {
    _title.dispose();
    _description.dispose();
    _newTag.dispose();
    super.dispose();
  }

  void _addTag() {
    final tag = _newTag.text.trim().toLowerCase().replaceAll(
      RegExp(r'\s+'),
      '-',
    );
    if (tag.isEmpty || _tags.contains(tag) || _tags.length >= 32) return;
    setState(() => _tags.add(tag));
    _newTag.clear();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final error = await Core.instance.updateFile(
      widget.file,
      title: _title.text,
      description: _description.text,
      tags: _tags,
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (error != null) {
      showMessage(context, error);
    } else {
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
        title: const Text('Edit details'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton(
              onPressed: _saving ? null : _save,
              child: _saving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Save'),
            ),
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 48),
            children: [
              Text(
                widget.file.path,
                style: const TextStyle(fontFamily: 'monospace'),
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
                  helperText: 'What it is, where it comes from, how to use it',
                  border: OutlineInputBorder(),
                ),
              ),
              const SectionTitle('Tags'),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final t in _tags)
                    InputChip(
                      label: Text(t),
                      onDeleted: () => setState(() => _tags.remove(t)),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _newTag,
                decoration: InputDecoration(
                  labelText: 'Add tag',
                  helperText: '${_tags.length} of 32',
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.add),
                    onPressed: _addTag,
                  ),
                ),
                onSubmitted: (_) => _addTag(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
