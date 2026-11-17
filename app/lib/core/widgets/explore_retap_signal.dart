import 'package:flutter/foundation.dart';

/// "Explore was tapped again": the shell's Explore destination fires it when
/// Explore is already the open tab with nothing pushed over it, and the
/// Trending tab answers (scroll to the top, or refresh when already there).
/// The same shape as `HomeRetapSignal`: a signal only, no state, living above
/// the router (`AppWidget`) so the shell and the screen need no shared key.
///
/// Deliberately not a `Listenable`: it is provided through a
/// `RepositoryProvider`, whose debug check rejects listenable values.
class ExploreRetapSignal {
  final List<VoidCallback> _listeners = [];

  void addListener(VoidCallback listener) => _listeners.add(listener);

  void removeListener(VoidCallback listener) => _listeners.remove(listener);

  /// Tells every listening screen (only a visible Trending tab acts).
  void retap() {
    for (final listener in List.of(_listeners)) {
      listener();
    }
  }

  void dispose() => _listeners.clear();
}
