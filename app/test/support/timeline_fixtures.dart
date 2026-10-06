import 'package:dzeroth/features/posts/data/posts_repository.dart';
import 'package:dzeroth/features/timeline/data/timeline_repository.dart';
import 'package:dzeroth/features/timeline/data/timeline_store.dart';
import 'package:mocktail/mocktail.dart';

import 'posts_fixtures.dart';

class MockTimelineRepository extends Mock implements TimelineRepository {}

class MockPostsRepository extends Mock implements PostsRepository {}

/// A cached post row, as the store keys it (`item_key` = `sort_key` =
/// `post_id`).
TimelineEntry postEntry(int n, {String authorId = 'u1', String text = ''}) {
  final view = postView(n, authorId: authorId, text: text);
  return TimelineEntry.post(postId(n), postId(n), view);
}

/// A gap marker directly below post [n].
TimelineEntry gapEntry(int n, {String token = 'gap-token'}) =>
    TimelineEntry.gap('gap-${postId(n)}', sortKeyBelow(postId(n)), token);

/// A snapshot of the posts [ids] (newest first), with optional gap rows
/// already placed in [entries] order via [extra].
TimelineSnapshot snapshotOf(
  List<int> ids, {
  String older = '',
  String since = 's',
  Map<int, TimelineEntry> gapAfter = const {},
  String authorId = 'u1',
}) {
  return TimelineSnapshot(
    entries: [
      for (final id in ids) ...[
        postEntry(id, authorId: authorId),
        if (gapAfter.containsKey(id)) gapAfter[id]!,
      ],
    ],
    sinceToken: since,
    olderPageToken: older,
  );
}
