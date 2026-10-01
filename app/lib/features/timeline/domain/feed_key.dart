import 'package:flutter/foundation.dart';

/// Identifies one cached timeline feed: the caller's home feed, or one tab of
/// one user's timeline. Its [value] is the drift `feed_key` and is also what
/// the server binds timeline tokens to (ADR-0010 D14), so a token is never
/// reused across feeds.
@immutable
class FeedKey {
  const FeedKey._(this.value, {this.userId, this.includeReplies = false});

  /// The caller's home timeline (followees + self).
  const FeedKey.home() : this._('home');

  /// [userId]'s Posts tab, or Replies tab when [includeReplies] is true.
  const FeedKey.user(String userId, {bool includeReplies = false})
    : this._(
        'user:$userId:${includeReplies ? 'replies' : 'posts'}',
        userId: userId,
        includeReplies: includeReplies,
      );

  final String value;

  /// Null for the home feed.
  final String? userId;
  final bool includeReplies;

  bool get isHome => userId == null;

  @override
  bool operator ==(Object other) => other is FeedKey && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'FeedKey($value)';
}
