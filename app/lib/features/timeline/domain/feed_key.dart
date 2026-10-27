import 'package:flutter/foundation.dart';

/// One tab of a user's timeline (`GetUserTimeline`, ADR-0024 D5). The enum
/// names are part of the drift `feed_key` (`user:<uid>:<name>`), so the first
/// two never change: caches written before Reposts and Media existed stay
/// valid.
enum UserFeedTab {
  /// Root posts (the Posts tab).
  posts,

  /// Posts and replies (the Replies tab).
  replies,

  /// The user's reposts, each with its embedded post (needs `profile_tabs`).
  reposts,

  /// The user's posts that carry their own images (needs `profile_tabs`).
  media;

  /// Whether the server answers this tab only while `profile_tabs` is on for
  /// the caller (FEATURE_DISABLED `feature=profile_tabs` otherwise).
  bool get requiresProfileTabs => this == reposts || this == media;
}

/// Identifies one cached timeline feed: the caller's home feed, or one tab of
/// one user's timeline. Its [value] is the drift `feed_key` and is also what
/// the server binds timeline tokens to (ADR-0010 D14, ADR-0024 D5: bound to
/// caller, target and effective tab), so a token is never reused across feeds
/// or tabs: every tab has its own cached rows, tokens and refresh clock.
@immutable
class FeedKey {
  const FeedKey._(this.value, {this.userId, this.tab});

  /// The caller's home timeline (followees + self).
  const FeedKey.home() : this._('home');

  /// [tab] of [userId]'s timeline. Without [tab], [includeReplies] picks the
  /// Posts (false) or Replies (true) tab, so every caller written before the
  /// other tabs existed keeps working and both styles name the same cache:
  /// `FeedKey.user(u, includeReplies: true) == FeedKey.user(u, tab:
  /// UserFeedTab.replies)`. A given [tab] wins over [includeReplies], as the
  /// server's `tab` wins over `include_replies`.
  factory FeedKey.user(
    String userId, {
    bool includeReplies = false,
    UserFeedTab? tab,
  }) {
    final effective =
        tab ?? (includeReplies ? UserFeedTab.replies : UserFeedTab.posts);
    return FeedKey._(
      'user:$userId:${effective.name}',
      userId: userId,
      tab: effective,
    );
  }

  final String value;

  /// Null for the home feed.
  final String? userId;

  /// Which tab of [userId]'s timeline; null for the home feed.
  final UserFeedTab? tab;

  bool get isHome => userId == null;

  /// True only for the Replies tab (what `include_replies` meant).
  bool get includeReplies => tab == UserFeedTab.replies;

  @override
  bool operator ==(Object other) => other is FeedKey && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'FeedKey($value)';
}
