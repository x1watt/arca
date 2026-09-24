import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/core_client.dart';
import 'common.dart';

/// Comments on a file or collection. Each one is a Nostr comment (kind 1111)
/// signed by the active profile and kept in its relay; reading others'
/// comments from circle relays comes with them (docs/architecture.md, 4).
class CommentsSection extends StatefulWidget {
  const CommentsSection({super.key, required this.target});

  /// NIP-73 identifier of what is commented on, such as `arca:sha256:` followed by the hash.
  final String target;

  @override
  State<CommentsSection> createState() => _CommentsSectionState();
}

class _CommentsSectionState extends State<CommentsSection> {
  final _text = TextEditingController();
  List<CommentView>? _comments;
  bool _posting = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(CommentsSection old) {
    super.didUpdateWidget(old);
    if (old.target != widget.target) _load();
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final list = await Core.instance.comments(widget.target);
    if (mounted) setState(() => _comments = list);
  }

  Future<void> _post() async {
    if (_text.text.trim().isEmpty) return;
    setState(() => _posting = true);
    final (error, list) = await Core.instance.comment(
      widget.target,
      _text.text,
    );
    if (!mounted) return;
    setState(() => _posting = false);
    if (error != null) {
      showMessage(context, error);
      return;
    }
    _text.clear();
    setState(() => _comments = list);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final me = Core.instance.state.value?.active;
    final comments = _comments;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionTitle(
          'Comments${comments == null || comments.isEmpty ? '' : '  ${comments.length}'}',
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CircleAvatar(
                radius: 18,
                child: Text(
                  me?.initials ?? '?',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: CallbackShortcuts(
                  // Enter posts; Shift+Enter starts a new line.
                  bindings: {
                    const SingleActivator(LogicalKeyboardKey.enter): _post,
                  },
                  child: TextField(
                    controller: _text,
                    minLines: 1,
                    maxLines: 4,
                    enabled: !_posting,
                    decoration: InputDecoration(
                      hintText: 'Add a comment...',
                      helperText:
                          'Signed by ${me?.name ?? 'your profile'} as a Nostr note',
                      suffixIcon: IconButton(
                        tooltip: 'Publish',
                        icon: _posting
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.send),
                        onPressed: _posting ? null : _post,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        if (comments == null)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (comments.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'No comments yet.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          )
        else
          for (final c in comments) _CommentTile(c),
      ],
    );
  }
}

class _CommentTile extends StatelessWidget {
  const _CommentTile(this.comment);
  final CommentView comment;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final initials = comment.author
        .split(' ')
        .where((w) => w.isNotEmpty)
        .take(2)
        .map((w) => w[0].toUpperCase())
        .join();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 18,
            child: Text(initials, style: const TextStyle(fontSize: 12)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        comment.author,
                        style: theme.textTheme.labelLarge,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (comment.mine) ...[
                      const SizedBox(width: 6),
                      Text('you', style: muted),
                    ],
                    const SizedBox(width: 8),
                    Text(timeAgo(comment.createdAt), style: muted),
                  ],
                ),
                const SizedBox(height: 4),
                SelectableText(comment.content),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
