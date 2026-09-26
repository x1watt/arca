// The device's power and connection, for the chain's "only while charging"
// and "only on Wi-Fi or a cable" choices. The plugins answer only on the UI
// isolate, so this watches here and tells the core when something changes.

import 'dart:async';

import 'package:battery_plus/battery_plus.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

import 'core_client.dart';

class PowerWatch {
  PowerWatch._();
  static final instance = PowerWatch._();

  bool? _charging;
  bool? _unmetered;
  final _subs = <StreamSubscription<Object?>>[];

  Future<void> start() async {
    final battery = Battery();
    final connectivity = Connectivity();
    _subs
      ..add(
        battery.onBatteryStateChanged.listen(
          (s) => _set(charging: _isCharging(s)),
        ),
      )
      ..add(
        connectivity.onConnectivityChanged.listen(
          (r) => _set(unmetered: _isUnmetered(r)),
        ),
      );
    try {
      _set(charging: _isCharging(await battery.batteryState));
    } catch (_) {
      _set(charging: true); // no battery to ask about: on mains
    }
    try {
      _set(unmetered: _isUnmetered(await connectivity.checkConnectivity()));
    } catch (_) {
      _set(unmetered: true);
    }
  }

  /// A computer without a battery reports "unknown": it runs on mains.
  static bool _isCharging(BatteryState s) => s != BatteryState.discharging;

  static bool _isUnmetered(List<ConnectivityResult> r) =>
      r.contains(ConnectivityResult.wifi) ||
      r.contains(ConnectivityResult.ethernet);

  void _set({bool? charging, bool? unmetered}) {
    final c = charging ?? _charging, u = unmetered ?? _unmetered;
    if (c == _charging && u == _unmetered) return;
    _charging = c;
    _unmetered = u;
    unawaited(
      Core.instance.setPower(charging: c ?? true, unmetered: u ?? true),
    );
  }
}
