// A NIP-01 relay that answers other clients over a MessageLink
// (docs/architecture.md, 4.2). Every Arca client runs one per profile.

import 'dart:async';

import '../nostr/event.dart';
import '../nostr/filter.dart';
import '../nostr/messages.dart';
import 'event_store.dart';

/// Decides whether an event may be stored; returns null to accept or a
/// NIP-01 reason ("blocked: ...", "rate-limited: ...") to refuse.
typedef AcceptPolicy = FutureOr<String?> Function(NostrEvent event, String from);

class _Sub {
  _Sub(this.filters, this.expires);
  final List<NostrFilter> filters;
  DateTime expires;
}

class NostrRelay {
  NostrRelay({
    required this.store,
    required this.reply,
    this.policy,
    this.subscriptionLifetime = const Duration(minutes: 10),
    this.maxSubscriptionsPerPeer = 20,
    this.maxEventsPerReq = 500,
    this.onStored,
    DateTime Function()? clock,
  }) : _now = clock ?? DateTime.now;

  final EventStore store;

  /// Sends a message back to a peer address.
  final Future<void> Function(String to, NostrMessage message) reply;
  final AcceptPolicy? policy;
  final Duration subscriptionLifetime;
  final int maxSubscriptionsPerPeer;
  final int maxEventsPerReq;

  /// Called after an event from another client is stored.
  final void Function(NostrEvent event)? onStored;
  final DateTime Function() _now;

  /// Live subscriptions: peer address to subscription id to filters.
  final _subs = <String, Map<String, _Sub>>{};

  /// Handles one client message from [from].
  Future<void> handle(String from, NostrMessage message) async {
    switch (message) {
      case EventMessage(:final event):
        await _onEvent(from, event);
      case ReqMessage(:final subscriptionId, :final filters):
        await _onReq(from, subscriptionId, filters);
      case CloseMessage(:final subscriptionId):
        _subs[from]?.remove(subscriptionId);
      default:
        // Relay-to-client messages are not for us.
        break;
    }
  }

  /// Stores an event produced locally (our own profile) and pushes it to
  /// live subscribers, without the network round trip.
  Future<AddResult> publishLocal(NostrEvent event) async {
    final r = await store.add(event);
    if (r == AddResult.added || r == AddResult.replacedOlder) await _fanOut(event);
    return r;
  }

  Future<void> _onEvent(String from, NostrEvent event) async {
    if (!event.verify()) {
      await reply(from, OkMessage(event.id, false, 'invalid: bad id or signature'));
      return;
    }
    final refusal = await policy?.call(event, from);
    if (refusal != null) {
      await reply(from, OkMessage(event.id, false, refusal));
      return;
    }
    final r = await store.add(event);
    final (ok, msg) = switch (r) {
      AddResult.added || AddResult.replacedOlder => (true, ''),
      AddResult.duplicate => (true, 'duplicate: already have this event'),
      AddResult.olderThanStored => (true, 'duplicate: have a newer version'),
      AddResult.deleted => (false, 'blocked: deleted by its author'),
    };
    await reply(from, OkMessage(event.id, ok, msg));
    if (r == AddResult.added || r == AddResult.replacedOlder) {
      onStored?.call(event);
      await _fanOut(event);
    }
  }

  Future<void> _onReq(String from, String id, List<NostrFilter> filters) async {
    if (id.isEmpty || id.length > 64) {
      await reply(from, ClosedMessage(id, 'invalid: subscription id'));
      return;
    }
    _expire();
    final peer = _subs.putIfAbsent(from, () => {});
    if (!peer.containsKey(id) && peer.length >= maxSubscriptionsPerPeer) {
      await reply(from, ClosedMessage(id, 'rate-limited: too many subscriptions'));
      return;
    }
    peer[id] = _Sub(filters, _now().add(subscriptionLifetime));
    final capped = [
      for (final f in filters)
        NostrFilter(
          ids: f.ids,
          authors: f.authors,
          kinds: f.kinds,
          tags: f.tags,
          since: f.since,
          until: f.until,
          limit: f.limit == null ? maxEventsPerReq : (f.limit! < maxEventsPerReq ? f.limit : maxEventsPerReq),
        ),
    ];
    for (final e in await store.query(capped)) {
      await reply(from, SubscriptionEvent(id, e));
    }
    await reply(from, EoseMessage(id));
  }

  Future<void> _fanOut(NostrEvent event) async {
    _expire();
    for (final peer in _subs.entries) {
      for (final sub in peer.value.entries) {
        if (sub.value.filters.any((f) => f.matches(event))) {
          await reply(peer.key, SubscriptionEvent(sub.key, event));
        }
      }
    }
  }

  void _expire() {
    final now = _now();
    for (final peer in _subs.values) {
      peer.removeWhere((_, s) => s.expires.isBefore(now));
    }
    _subs.removeWhere((_, m) => m.isEmpty);
  }

  int get liveSubscriptions => _subs.values.fold(0, (n, m) => n + m.length);
}
