/// The only vocabulary [UsageAnalytics.log] accepts.
///
/// Three events. Every parameter is a Dart enum or a bool, so a person's text,
/// handle, id or query cannot be passed (it would not compile). A new event or
/// parameter changes the policy in the same PR.
///
/// [name] and [parameters] are the wire form. `firebase_usage_analytics.dart`
/// sends them as they are; nothing else is added (no user id, no user
/// property, no default parameter).
sealed class AnalyticsEvent {
  const AnalyticsEvent();

  /// The Analytics event name (lower snake case, fixed).
  String get name;

  /// Fixed keys, string values: an enum's `name`, or `true` / `false` (the
  /// Analytics SDK takes strings and numbers only).
  Map<String, Object> get parameters;
}

/// What kind of post was created.
enum PostKind { post, reply, quote }

/// What media a created post carries.
enum PostMedia { none, photo, gif }

/// A post the server accepted (`CreatePost` or `SchedulePost`).
final class PostCreated extends AnalyticsEvent {
  const PostCreated({
    required this.kind,
    required this.media,
    required this.poll,
    required this.scheduled,
  });

  final PostKind kind;
  final PostMedia media;
  final bool poll;
  final bool scheduled;

  @override
  String get name => 'post_created';

  @override
  Map<String, Object> get parameters => {
    'kind': kind.name,
    'media': media.name,
    'poll': '$poll',
    'scheduled': '$scheduled',
  };
}

/// Where a follow was made.
enum FollowSource { profile, suggestions, search, list, other }

/// A follow (or follow request) the server confirmed.
final class FollowMade extends AnalyticsEvent {
  const FollowMade({required this.source});

  final FollowSource source;

  @override
  String get name => 'follow';

  @override
  Map<String, Object> get parameters => {'source': source.name};
}

/// What a search looked for.
enum SearchType { people, hashtag }

/// A search the person submitted or a result they opened. Never the query.
final class SearchUsed extends AnalyticsEvent {
  const SearchUsed({required this.type});

  final SearchType type;

  @override
  String get name => 'search_used';

  @override
  Map<String, Object> get parameters => {'type': type.name};
}
