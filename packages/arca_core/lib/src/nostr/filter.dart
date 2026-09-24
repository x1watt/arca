// NIP-01 subscription filters.

import 'event.dart';

class NostrFilter {
  const NostrFilter({
    this.ids,
    this.authors,
    this.kinds,
    this.tags = const {},
    this.since,
    this.until,
    this.limit,
  });

  final List<String>? ids;
  final List<String>? authors;
  final List<int>? kinds;

  /// Single-letter tag filters, keyed without the '#': {'e': [...], 'I': [...]}.
  final Map<String, List<String>> tags;
  final int? since;
  final int? until;
  final int? limit;

  bool matches(NostrEvent e) {
    if (ids != null && !ids!.contains(e.id)) return false;
    if (authors != null && !authors!.contains(e.pubkey)) return false;
    if (kinds != null && !kinds!.contains(e.kind)) return false;
    if (since != null && e.createdAt < since!) return false;
    if (until != null && e.createdAt > until!) return false;
    for (final entry in tags.entries) {
      final values = e.tagValues(entry.key).toSet();
      if (!entry.value.any(values.contains)) return false;
    }
    return true;
  }

  Map<String, Object> toJson() => {
    'ids': ?ids,
    'authors': ?authors,
    'kinds': ?kinds,
    for (final t in tags.entries) '#${t.key}': t.value,
    'since': ?since,
    'until': ?until,
    'limit': ?limit,
  };

  factory NostrFilter.fromJson(Object? json) {
    if (json is! Map) throw const FormatException('filter must be an object');
    try {
      List<String>? strings(String k) => (json[k] as List?)?.cast<String>().toList();
      return NostrFilter(
        ids: strings('ids'),
        authors: strings('authors'),
        kinds: (json['kinds'] as List?)?.cast<int>().toList(),
        tags: {
          for (final k in json.keys)
            if (k is String && k.length == 2 && k.startsWith('#'))
              k.substring(1): (json[k] as List).cast<String>().toList(),
        },
        since: json['since'] as int?,
        until: json['until'] as int?,
        limit: json['limit'] as int?,
      );
    } on TypeError {
      throw const FormatException('filter field of the wrong type');
    }
  }
}
