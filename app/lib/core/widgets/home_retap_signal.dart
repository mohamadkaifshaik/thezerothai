import 'package:flutter/foundation.dart';

/// "Home was tapped again": the shell's Home destination fires it when Home is
/// already the open tab, and the visible Home feed answers (scroll to the top,
/// or refresh when already there). A signal only, no state: it lives above the
/// router (`AppWidget`) so the shell and the feed need no shared key.
///
/// Deliberately not a `Listenable`: it is provided through a
/// `RepositoryProvider`, whose debug check rejects listenable values.
class HomeRetapSignal {
  final List<VoidCallback> _listeners = [];

  void addListener(VoidCallback listener) => _listeners.add(listener);

  void removeListener(VoidCallback listener) => _listeners.remove(listener);

  /// Tells every listening feed (only the active one acts).
  void retap() {
    for (final listener in List.of(_listeners)) {
      listener();
    }
  }

  void dispose() => _listeners.clear();
}
