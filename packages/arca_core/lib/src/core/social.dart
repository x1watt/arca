// People a profile follows, what their relays last told us about them, and
// the Arca address used to find someone (docs/architecture.md, 5.4).

import 'dart:convert';
import 'dart:io';

import '../crypto/hex.dart';
import '../nostr/nip19.dart';

/// Metadata changes suggested for a file in someone else's collection
/// (provisional kind until the protocol is fixed). Regular event, tagged
/// with the owner (`p`), the collection (`a`) and the file's hash (`x`).
const kindProposal = 4781;

/// `arca:<npub>@<address>.b32.i2p`, how a profile is shared by hand until
/// circles and relay lists do it automatically.
String arcaAddress(String npub, String i2p) => 'arca:$npub@$i2p';

/// Parses an Arca address into (pubkey hex, I2P address); throws
/// [FormatException] with a readable message.
(String, String) parseArcaAddress(String input) {
  var s = input.trim();
  if (s.startsWith('arca:')) s = s.substring(5);
  final at = s.indexOf('@');
  if (at < 0) throw const FormatException('An Arca address looks like arca:npub1...@....b32.i2p');
  final npub = s.substring(0, at), i2p = s.substring(at + 1).toLowerCase();
  if (!RegExp(r'^[a-z2-7]{52}\.b32\.i2p$').hasMatch(i2p)) {
    throw const FormatException('The part after @ must be an I2P address ending in .b32.i2p');
  }
  try {
    return (toHex(decodeEntity(npub, 'npub')), i2p);
  } on FormatException {
    throw const FormatException('The part before @ must be an npub');
  }
}

class Follow {
  Follow({required this.pubkey, required this.address, this.name = ''});
  final String pubkey;
  final String address;
  String name;

  /// Collection events last fetched, keyed by collection id.
  Map<String, Map<String, Object?>> collections = {};

  /// Proposal id to decision ('accepted' or 'rejected') as published by the owner.
  Map<String, String> decisions = {};
  int? fetchedAt;
  String? error;
  bool refreshing = false;

  Map<String, Object?> toJson() => {
    'pubkey': pubkey,
    'address': address,
    'name': name,
    'collections': collections,
    'decisions': decisions,
    'fetchedAt': fetchedAt,
  };

  factory Follow.fromJson(Map<String, dynamic> m) => Follow(
    pubkey: m['pubkey'] as String,
    address: m['address'] as String,
    name: m['name'] as String? ?? '',
  )
    ..collections = {
      for (final e in (m['collections'] as Map? ?? {}).entries)
        e.key as String: (e.value as Map).cast<String, Object?>(),
    }
    ..decisions = (m['decisions'] as Map? ?? {}).cast<String, String>()
    ..fetchedAt = m['fetchedAt'] as int?;
}

class FollowStore {
  FollowStore._(this._file, this.follows);
  final File _file;
  final List<Follow> follows;

  static Future<FollowStore> open(File f) async {
    final list = <Follow>[];
    if (await f.exists()) {
      for (final m in jsonDecode(await f.readAsString()) as List) {
        list.add(Follow.fromJson(m as Map<String, dynamic>));
      }
    }
    return FollowStore._(f, list);
  }

  Follow? byPubkey(String pk) => follows.where((f) => f.pubkey == pk).firstOrNull;

  Future<void> save() async {
    final tmp = File('${_file.path}.tmp');
    await tmp.writeAsString(jsonEncode([for (final f in follows) f.toJson()]), flush: true);
    await tmp.rename(_file.path);
  }
}
