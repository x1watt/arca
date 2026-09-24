// NIP-01 relay messages, encoded as JSON arrays. Arca carries each message in
// one I2P application message (docs/architecture.md, 4.2).

import 'dart:convert';
import 'dart:typed_data';

import 'event.dart';
import 'filter.dart';

/// Largest encoded message that fits one I2P application message.
const maxMessageBytes = 32 * 1024;

sealed class NostrMessage {
  const NostrMessage();

  List<Object?> toJson();

  Uint8List encode() => Uint8List.fromList(utf8.encode(jsonEncode(toJson())));

  /// Parses one message; throws [FormatException] for anything malformed.
  static NostrMessage decode(List<int> bytes) {
    final Object? json;
    try {
      json = jsonDecode(utf8.decode(bytes));
    } on FormatException {
      throw const FormatException('not JSON');
    }
    if (json is! List || json.isEmpty || json[0] is! String) {
      throw const FormatException('not a relay message');
    }
    final type = json[0] as String;
    try {
      return switch (type) {
        'EVENT' when json.length == 2 => EventMessage(NostrEvent.fromJson(json[1])),
        'EVENT' when json.length == 3 => SubscriptionEvent(json[1] as String, NostrEvent.fromJson(json[2])),
        'REQ' when json.length >= 3 => ReqMessage(
          json[1] as String,
          [for (final f in json.sublist(2)) NostrFilter.fromJson(f)],
        ),
        'CLOSE' when json.length == 2 => CloseMessage(json[1] as String),
        'EOSE' when json.length == 2 => EoseMessage(json[1] as String),
        'OK' when json.length == 4 => OkMessage(json[1] as String, json[2] as bool, json[3] as String),
        'CLOSED' when json.length == 3 => ClosedMessage(json[1] as String, json[2] as String),
        'NOTICE' when json.length == 2 => NoticeMessage(json[1] as String),
        _ => throw FormatException('unknown message $type'),
      };
    } on TypeError {
      throw FormatException('malformed $type');
    }
  }
}

/// Client to relay: publish an event.
class EventMessage extends NostrMessage {
  const EventMessage(this.event);
  final NostrEvent event;
  @override
  List<Object?> toJson() => ['EVENT', event.toJson()];
}

/// Relay to client: an event for a subscription.
class SubscriptionEvent extends NostrMessage {
  const SubscriptionEvent(this.subscriptionId, this.event);
  final String subscriptionId;
  final NostrEvent event;
  @override
  List<Object?> toJson() => ['EVENT', subscriptionId, event.toJson()];
}

class ReqMessage extends NostrMessage {
  const ReqMessage(this.subscriptionId, this.filters);
  final String subscriptionId;
  final List<NostrFilter> filters;
  @override
  List<Object?> toJson() => ['REQ', subscriptionId, for (final f in filters) f.toJson()];
}

class CloseMessage extends NostrMessage {
  const CloseMessage(this.subscriptionId);
  final String subscriptionId;
  @override
  List<Object?> toJson() => ['CLOSE', subscriptionId];
}

class EoseMessage extends NostrMessage {
  const EoseMessage(this.subscriptionId);
  final String subscriptionId;
  @override
  List<Object?> toJson() => ['EOSE', subscriptionId];
}

class OkMessage extends NostrMessage {
  const OkMessage(this.eventId, this.accepted, this.message);
  final String eventId;
  final bool accepted;
  final String message;
  @override
  List<Object?> toJson() => ['OK', eventId, accepted, message];
}

class ClosedMessage extends NostrMessage {
  const ClosedMessage(this.subscriptionId, this.message);
  final String subscriptionId;
  final String message;
  @override
  List<Object?> toJson() => ['CLOSED', subscriptionId, message];
}

class NoticeMessage extends NostrMessage {
  const NoticeMessage(this.message);
  final String message;
  @override
  List<Object?> toJson() => ['NOTICE', message];
}
