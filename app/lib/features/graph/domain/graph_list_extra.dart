import 'package:flutter/foundation.dart';

/// What whoever opens `/profile/:handle/followers` or `.../following` already
/// knows about the person: their uid (so the screen needs no `GetProfile`)
/// and their display name (the page's title, the handle its subtitle). A deep
/// link or a reload carries none of it and the screen falls back to resolving
/// the uid and titling itself with the `@handle`.
@immutable
class GraphListExtra {
  const GraphListExtra({required this.userId, required this.displayName});

  final String userId;
  final String displayName;
}
