// One profile's presence on the network: its relay (answering others) and
// its client (publishing to and querying others), sharing one address.

import 'dart:async';
import 'dart:math';

import '../nostr/event.dart';
import '../nostr/filter.dart';
import '../nostr/messages.dart';
import '../transport/link.dart';
import 'event_store.dart';
import 'relay.dart';

class PublishResult {
  const PublishResult(this.accepted, this.message, {this.attempts = 1});
  final bool accepted;
  final String message;
  final int attempts;
  bool get timedOut => message == 'timeout';
}

class NostrNode {
  NostrNode({
    required this.address,
    required this.link,
    required EventStore store,
    AcceptPolicy? policy,
    void Function(NostrEvent event)? onStored,
  }) {
    relay = NostrRelay(store: store, policy: policy, reply: _send, onStored: onStored);
    _sub = link.incoming.where((m) => m.to == address).listen(_onInbound);
  }

  /// This profile's address on the network.
  final String address;
  final MessageLink link;
  late final NostrRelay relay;
  late final StreamSubscription<Inbound> _sub;

  /// First pause before resending a message the network did not take.
  Duration retryDelay = const Duration(seconds: 3);
  final _rng = Random.secure();

  /// Waiters for OK by (peer, event id), and for query results by
  /// (peer, subscription id).
  final _okWaiters = <String, Completer<OkMessage>>{};
  final _queries = <String, _Query>{};

  Future<void> _send(String to, NostrMessage m) async {
    await _trySend(to, m);
  }

  /// True when the network took the message (not that it arrived).
  Future<bool> _trySend(String to, NostrMessage m) async {
    final bytes = m.encode();
    if (bytes.length > maxMessageBytes) return false;
    return link.send(to, bytes, from: address);
  }

  /// Sends until the network takes the message or [deadline] passes. On
  /// I2P a fresh address can be briefly unfindable while its lease set
  /// spreads, so a refused send is retried within seconds, not after a
  /// full timeout.
  Future<bool> _sendPersistently(String to, NostrMessage m, DateTime deadline) async {
    var wait = retryDelay;
    while (true) {
      if (await _trySend(to, m)) return true;
      if (DateTime.now().add(wait).isAfter(deadline)) return false;
      await Future<void>.delayed(wait);
      if (wait < const Duration(seconds: 20)) wait *= 2;
    }
  }

  void _onInbound(Inbound m) {
    final NostrMessage msg;
    try {
      msg = NostrMessage.decode(m.bytes);
    } on FormatException {
      return;
    }
    switch (msg) {
      case EventMessage() || ReqMessage() || CloseMessage():
        relay.handle(m.from, msg);
      case OkMessage(:final eventId):
        final w = _okWaiters.remove('${m.from}|$eventId');
        if (w != null && !w.isCompleted) w.complete(msg);
      case SubscriptionEvent(:final subscriptionId, :final event):
        _queries['${m.from}|$subscriptionId']?.add(event);
      case EoseMessage(:final subscriptionId):
        _queries['${m.from}|$subscriptionId']?.end();
      case ClosedMessage(:final subscriptionId):
        _queries['${m.from}|$subscriptionId']?.end();
      case NoticeMessage():
        break;
    }
  }

  /// Publishes [event] to the relay at [to], retrying with backoff until an
  /// OK arrives or [attempts] run out (I2P delivery is best effort).
  Future<PublishResult> publish(
    String to,
    NostrEvent event, {
    int attempts = 4,
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final key = '$to|${event.id}';
    for (var i = 1; i <= attempts; i++) {
      final waiter = _okWaiters[key] ?? Completer<OkMessage>();
      _okWaiters[key] = waiter;
      if (!await _sendPersistently(to, EventMessage(event), DateTime.now().add(timeout * i))) continue;
      try {
        final ok = await waiter.future.timeout(timeout * i);
        return PublishResult(ok.accepted, ok.message, attempts: i);
      } on TimeoutException {
        continue;
      }
    }
    _okWaiters.remove(key);
    return PublishResult(false, 'timeout', attempts: attempts);
  }

  /// Asks the relay at [to] for events matching [filters] and returns them
  /// once it signals the end of stored events. Unverifiable events are
  /// dropped. Returns what arrived when [timeout] passes without EOSE.
  Future<List<NostrEvent>> query(
    String to,
    List<NostrFilter> filters, {
    Duration timeout = const Duration(seconds: 15),
    int attempts = 2,
  }) async {
    for (var i = 1; i <= attempts; i++) {
      final id = List.generate(8, (_) => _rng.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
      final q = _Query();
      _queries['$to|$id'] = q;
      final deadline = DateTime.now().add(timeout);
      if (!await _sendPersistently(to, ReqMessage(id, filters), deadline)) {
        _queries.remove('$to|$id');
        continue;
      }
      final left = deadline.difference(DateTime.now());
      final done = left.isNegative ? false : await q.done.future.timeout(left, onTimeout: () => false);
      _queries.remove('$to|$id');
      await _send(to, CloseMessage(id));
      if (done || q.events.isNotEmpty || i == attempts) {
        return q.events.values.where((e) => e.verify()).toList()..sort((a, b) => b.createdAt.compareTo(a.createdAt));
      }
    }
    return const [];
  }

  Future<void> close() async {
    await _sub.cancel();
  }
}

class _Query {
  final events = <String, NostrEvent>{};
  final done = Completer<bool>();
  void add(NostrEvent e) => events[e.id] = e;
  void end() {
    if (!done.isCompleted) done.complete(true);
  }
}
