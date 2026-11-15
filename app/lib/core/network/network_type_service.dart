import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

/// Whether the current connection is metered (mobile data) or not (Wi-Fi,
/// ethernet). The Data usage settings ask it; nothing else does.
///
/// An interface so tests never touch the connectivity plugin
/// (`FakeNetworkTypeService` in `test/support`).
abstract interface class NetworkTypeService {
  /// The last known type. Before the first check on a phone it is metered
  /// (the cautious guess, so a "Wi-Fi only" choice never spends mobile data
  /// while the answer is on its way); on the web it is unmetered.
  bool get metered;

  /// Emits whenever [metered] changes (never repeats a value).
  Stream<bool> get meteredChanges;

  /// False where the platform cannot tell Wi-Fi from mobile data (the web):
  /// the connection then counts as unmetered, and the settings page says so.
  bool get canDistinguish;

  /// Stops listening.
  void dispose();
}

/// Whether [results] describe a metered connection.
///
/// - Wi-Fi or ethernet anywhere in the list: unmetered (a VPN over Wi-Fi is
///   `[vpn, wifi]`).
/// - On the web, where the type is often unknown: unmetered.
/// - Otherwise (mobile, bluetooth, vpn alone, other, none): metered.
bool isMeteredConnection(
  List<ConnectivityResult> results, {
  required bool web,
}) {
  if (results.contains(ConnectivityResult.wifi) ||
      results.contains(ConnectivityResult.ethernet)) {
    return false;
  }
  return !web;
}

/// [NetworkTypeService] over `connectivity_plus`. A plugin failure never
/// breaks the app: the value then stays what it was.
class ConnectivityNetworkTypeService implements NetworkTypeService {
  ConnectivityNetworkTypeService({Connectivity? connectivity, bool? web})
    : _web = web ?? kIsWeb {
    _metered = !_web;
    try {
      final plugin = connectivity ?? Connectivity();
      _sub = plugin.onConnectivityChanged.listen(_apply, onError: _onError);
      unawaited(plugin.checkConnectivity().then(_apply).catchError(_onError));
    } on Object catch (error, stack) {
      _log.warning('connectivity is not available', error, stack);
    }
  }

  static final _log = Logger('NetworkTypeService');

  final bool _web;
  late bool _metered;
  StreamSubscription<List<ConnectivityResult>>? _sub;
  final _changes = StreamController<bool>.broadcast();

  @override
  bool get metered => _metered;

  @override
  Stream<bool> get meteredChanges => _changes.stream;

  @override
  bool get canDistinguish => !_web;

  void _apply(List<ConnectivityResult> results) {
    final next = isMeteredConnection(results, web: _web);
    if (next == _metered || _changes.isClosed) return;
    _metered = next;
    _changes.add(next);
  }

  void _onError(Object error, StackTrace stack) {
    _log.warning('could not read the connection type', error, stack);
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    unawaited(_changes.close());
  }
}
