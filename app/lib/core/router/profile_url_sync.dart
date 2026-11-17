import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart' show SystemNavigator;

/// Writes [uri] over the browser's current history entry (no new entry).
typedef BrowserUrlReplacer = void Function(Uri uri);

/// Replaces the address bar without a history entry. Web only: a no-op on
/// Android and iOS. Not a navigation: the router keeps its own location, so
/// nothing rebuilds or refetches.
void replaceBrowserUrl(Uri uri) {
  if (!kIsWeb) return;
  SystemNavigator.routeInformationUpdated(uri: uri, replace: true);
}

/// Privacy: a profile opened by id (`/u/<userId>`) shows `/profile/<handle>` in
/// the browser once the handle is known, so the uid does not sit in the
/// address bar. Deep links to `/u/<userId>` keep working (and a refresh on
/// the handle form opens the handle route).
class ProfileUrlSync {
  const ProfileUrlSync({BrowserUrlReplacer replacer = replaceBrowserUrl})
    : _replace = replacer;

  final BrowserUrlReplacer _replace;

  /// The address-bar URI for [handle], or null when there is none (empty).
  static Uri? handleUri(String handle) {
    final h = handle.trim().replaceFirst(RegExp(r'^@'), '');
    if (h.isEmpty) return null;
    return Uri(pathSegments: ['', 'profile', h]);
  }

  /// Shows the handle form for a profile that was requested by
  /// [requestedUserId]. Returns whether the URL was replaced. Only acts when
  /// the loaded profile is that same user and has a handle.
  bool showHandle({
    required String requestedUserId,
    required String loadedUserId,
    required String handle,
  }) {
    if (requestedUserId.isEmpty || requestedUserId != loadedUserId) {
      return false;
    }
    final uri = handleUri(handle);
    if (uri == null) return false;
    _replace(uri);
    return true;
  }
}
