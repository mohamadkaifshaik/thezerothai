import 'dart:async';

import 'package:flutter/foundation.dart';

/// Turns one or more [Stream]s into a [Listenable] `go_router` can use as
/// `refreshListenable`, so route redirects re-evaluate whenever auth or
/// onboarding state changes — without polling.
class GoRouterRefreshStream extends ChangeNotifier {
  GoRouterRefreshStream(Iterable<Stream<dynamic>> streams) {
    notifyListeners();
    for (final stream in streams) {
      _subscriptions.add(stream.listen((_) => notifyListeners()));
    }
  }

  final List<StreamSubscription<dynamic>> _subscriptions = [];

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    super.dispose();
  }
}
