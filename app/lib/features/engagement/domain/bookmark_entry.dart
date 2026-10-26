import 'package:flutter/foundation.dart';

import '../../../gen/dzeroth/posts/v1/posts.pb.dart' as pb;

/// What the viewer's "bookmarked" state of one post looks like in the
/// session (ADR-0023 D3, plan W2-6). One entry per post the session knows
/// about: the ones the user toggled, plus (W2-7) every post of a
/// ListBookmarks page.
///
/// Precedence of [resolve], the single rule every caller uses:
/// 1. A post the user toggled in this session ([touched]) shows the session
///    state while a request is running, and also while the row still says what
///    it said when the user acted ([base]): a cached row must not undo a
///    toggle. A refreshed row that says something else is newer and wins.
/// 2. Otherwise the server's own flag on the row, when the row has one.
/// 3. Otherwise the local set (this entry), else "not bookmarked".
@immutable
class BookmarkEntry {
  const BookmarkEntry({
    required this.saved,
    this.busy = false,
    this.touched = false,
    this.base,
  });

  /// The state to show: the confirmed state with the user's latest intent
  /// applied.
  final bool saved;

  /// A request is in flight.
  final bool busy;

  /// The user toggled this post in this session (false: only a list page said
  /// it is bookmarked).
  final bool touched;

  /// What the row said (the server flag, `null` when it had none) when the
  /// user first acted.
  final bool? base;

  /// The value to show for a row whose server flag is [server] (`null`: the
  /// row carries none).
  bool resolve(bool? server) {
    if (server == null) return saved;
    if (!touched) return server;
    return (busy || server == base) ? saved : server;
  }

  @override
  bool operator ==(Object other) =>
      other is BookmarkEntry &&
      other.saved == saved &&
      other.busy == busy &&
      other.touched == touched &&
      other.base == base;

  @override
  int get hashCode => Object.hash(saved, busy, touched, base);
}

/// The server's own "bookmarked" flag of a feed row, or `null` when the row
/// carries none. THE one place the client reads `PostView.bookmarked_by_viewer`
/// (ADR-0023 D3, Q2 = B); everything else asks `BookmarksCubit`.
///
/// For a REPOST row the flag describes the original, as `liked_by_viewer`
/// does.
bool? serverBookmarkedOf(pb.PostView view) {
  // TODO(W2-1b): when PostView.bookmarked_by_viewer exists, replace the body
  // with `return view.bookmarkedByViewer;` (the single line to flip).
  return null;
}
