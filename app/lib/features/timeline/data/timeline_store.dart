import 'package:drift/drift.dart';

import '../../../core/storage/app_database.dart';
import '../../../gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import '../domain/feed_key.dart';

/// Newest posts kept per feed (posts-and-timeline plan T14).
const kTimelineRetention = 500;

/// One row of a cached feed: a post, or a gap marker between two runs of
/// posts (the "show more" row of ADR-0004 / ADR-0010 D14).
class TimelineEntry {
  const TimelineEntry.post(this.itemKey, this.sortKey, this.postView)
    : gapToken = null;
  const TimelineEntry.gap(this.itemKey, this.sortKey, String this.gapToken)
    : postView = null;

  final String itemKey;
  final String sortKey;
  final pb.PostView? postView;
  final String? gapToken;

  bool get isGap => gapToken != null;
}

/// What the UI renders from disk, with no network call.
class TimelineSnapshot {
  const TimelineSnapshot({
    this.entries = const [],
    this.sinceToken = '',
    this.olderPageToken = '',
  });

  /// Newest first, posts and gap markers interleaved at their positions.
  final List<TimelineEntry> entries;
  final String sinceToken;
  final String olderPageToken;

  Iterable<pb.PostView> get posts => [
    for (final e in entries)
      if (e.postView != null) e.postView!,
  ];

  bool get hasMore => olderPageToken.isNotEmpty;
}

/// Zero-padded 19-digit id just below [postId], used to place a gap marker
/// directly under the oldest item above it. Ids stay strings (a 19-digit
/// Snowflake does not fit a JS number).
String sortKeyBelow(String postId) {
  final n = BigInt.tryParse(postId);
  if (n == null || n <= BigInt.zero) return postId;
  return (n - BigInt.one).toString().padLeft(postId.length, '0');
}

/// Persists timeline feeds in drift ([AppDatabase.timelineItemEntries] and
/// [AppDatabase.timelineStateEntries]) and implements every merge rule in
/// one place. Every method is one transaction, so a crash never leaves a
/// half-merged feed.
///
/// Rules: a post is stored once per feed, keyed by `post_id` (refreshes may
/// repeat items from the server's settle window, ADR-0010 D13); rows sort by
/// `post_id` descending; only the newest [kTimelineRetention] posts per feed
/// are kept.
class TimelineStore {
  TimelineStore(this._db);

  final AppDatabase _db;

  Future<TimelineSnapshot> read(FeedKey feed) async {
    final rows =
        await (_db.select(_db.timelineItemEntries)
              ..where((t) => t.feedKey.equals(feed.value))
              ..orderBy([(t) => OrderingTerm.desc(t.sortKey)]))
            .get();
    final entries = <TimelineEntry>[];
    for (final row in rows) {
      final payload = row.payload;
      if (payload != null) {
        try {
          entries.add(
            TimelineEntry.post(
              row.itemKey,
              row.sortKey,
              pb.PostView.fromBuffer(payload),
            ),
          );
        } catch (_) {
          // Undecodable row (schema drift): skip it, the next refresh
          // re-fetches it.
        }
      } else if (row.gapToken != null) {
        entries.add(TimelineEntry.gap(row.itemKey, row.sortKey, row.gapToken!));
      }
    }
    final state = await _state(feed);
    return TimelineSnapshot(
      entries: entries,
      sinceToken: state?.sinceToken ?? '',
      olderPageToken: state?.olderPageToken ?? '',
    );
  }

  /// Merges a `since_token` refresh response. A non-empty [gapPageToken]
  /// persists a gap row directly below the oldest returned post.
  Future<void> applyRefresh(
    FeedKey feed, {
    required List<pb.PostView> posts,
    required String sinceToken,
    required String gapPageToken,
  }) {
    return _db.transaction(() async {
      final valid = _valid(posts);
      await _upsertPosts(feed, valid);
      if (gapPageToken.isNotEmpty && valid.isNotEmpty) {
        await _putGap(
          feed,
          sortKeyBelow(valid.last.post.postId),
          gapPageToken,
        );
      }
      await _saveState(feed, sinceToken: sinceToken);
      await _prune(feed);
    });
  }

  /// Merges a cold-open response (no tokens sent).
  ///
  /// - [replace] false: the page is merged into the cache. If the cache was
  ///   empty its `next_page_token` becomes the scroll token. If it was not,
  ///   the page's `next_page_token` is stored as a gap row below the page
  ///   unless the page already reached a cached post (nothing missing). The
  ///   cached items stay visible throughout (rejected `since_token`, D14).
  /// - [replace] true: the feed is rebuilt from this page (a rejected
  ///   `page_token`; the old gap tokens are unusable).
  Future<void> applyColdOpen(
    FeedKey feed, {
    required List<pb.PostView> posts,
    required String sinceToken,
    required String nextPageToken,
    bool replace = false,
  }) {
    return _db.transaction(() async {
      if (replace) await _deleteFeedRows(feed);
      final existing = await _postIds(feed);
      final valid = _valid(posts);
      await _upsertPosts(feed, valid);
      if (existing.isEmpty) {
        await _saveState(
          feed,
          sinceToken: sinceToken,
          olderPageToken: nextPageToken,
        );
      } else {
        if (nextPageToken.isNotEmpty &&
            valid.isNotEmpty &&
            !existing.contains(valid.last.post.postId)) {
          await _putGap(
            feed,
            sortKeyBelow(valid.last.post.postId),
            nextPageToken,
          );
        }
        await _saveState(feed, sinceToken: sinceToken);
      }
      await _prune(feed);
    });
  }

  /// Merges a scroll-down page into the tail.
  Future<void> applyOlderPage(
    FeedKey feed, {
    required List<pb.PostView> posts,
    required String nextPageToken,
  }) {
    return _db.transaction(() async {
      await _upsertPosts(feed, _valid(posts));
      await _saveState(feed, olderPageToken: nextPageToken);
      await _prune(feed);
    });
  }

  /// Merges one page that fills the gap row [gapItemKey]. Merging stops at
  /// the first post already cached (the gap is then closed, ADR-0010 D14);
  /// otherwise the gap row moves below the page with the new token, or is
  /// removed when `next_page_token` is empty.
  Future<void> applyGapPage(
    FeedKey feed,
    String gapItemKey, {
    required List<pb.PostView> posts,
    required String nextPageToken,
  }) {
    return _db.transaction(() async {
      final gap =
          await (_db.select(_db.timelineItemEntries)..where(
                (t) =>
                    t.feedKey.equals(feed.value) & t.itemKey.equals(gapItemKey),
              ))
              .getSingleOrNull();
      final existing = await _postIds(feed);
      final fresh = <pb.PostView>[];
      var reachedCached = false;
      for (final view in _valid(posts)) {
        if (existing.contains(view.post.postId)) {
          reachedCached = true;
          break;
        }
        fresh.add(view);
      }
      await _upsertPosts(feed, fresh);
      if (gap != null) await _deleteItem(feed, gapItemKey);
      if (!reachedCached && nextPageToken.isNotEmpty) {
        final key = fresh.isNotEmpty
            ? sortKeyBelow(fresh.last.post.postId)
            : gap?.sortKey;
        if (key != null) await _putGap(feed, key, nextPageToken);
      }
      await _prune(feed);
    });
  }

  /// Drops the stored `since_token` (it was rejected, D14).
  Future<void> clearSince(FeedKey feed) =>
      _saveState(feed, sinceToken: '', replaceSince: true);

  /// Removes [postId] from every cached feed (post NOT_FOUND on open, or
  /// the caller deleted it).
  Future<void> removePost(String postId) {
    return (_db.delete(
      _db.timelineItemEntries,
    )..where((t) => t.itemKey.equals(postId))).go();
  }

  /// Forgets a feed entirely (its user is gone, or blocks the caller).
  Future<void> removeFeed(FeedKey feed) {
    return _db.transaction(() async {
      await _deleteFeedRows(feed);
      await (_db.delete(
        _db.timelineStateEntries,
      )..where((t) => t.feedKey.equals(feed.value))).go();
    });
  }

  /// Puts a post the caller just created at the top of every feed that has
  /// already been loaded (has a `since_token`). The next refresh returns it
  /// again and the merge dedupes it. Feeds never loaded stay empty, so a
  /// cold start never shows a one-post feed.
  Future<void> insertOwnPost(
    pb.PostView view, {
    required Iterable<FeedKey> feeds,
  }) {
    return _db.transaction(() async {
      if (view.post.postId.isEmpty) return;
      for (final feed in feeds) {
        final state = await _state(feed);
        if (state == null || state.sinceToken.isEmpty) continue;
        await _upsertPosts(feed, [view]);
        await _prune(feed);
      }
    });
  }

  // --- internals -----------------------------------------------------------

  List<pb.PostView> _valid(List<pb.PostView> views) => [
    for (final v in views)
      if (v.post.postId.isNotEmpty) v,
  ];

  Future<CachedTimelineState?> _state(FeedKey feed) {
    return (_db.select(
      _db.timelineStateEntries,
    )..where((t) => t.feedKey.equals(feed.value))).getSingleOrNull();
  }

  /// Updates the state row. A null/empty token leaves the stored one alone
  /// (a response with no `since_token` must not erase the old one) unless
  /// [replaceSince] is set.
  Future<void> _saveState(
    FeedKey feed, {
    String? sinceToken,
    String? olderPageToken,
    bool replaceSince = false,
  }) async {
    final old = await _state(feed);
    final since = replaceSince
        ? (sinceToken ?? '')
        : ((sinceToken == null || sinceToken.isEmpty)
              ? (old?.sinceToken ?? '')
              : sinceToken);
    await _db
        .into(_db.timelineStateEntries)
        .insertOnConflictUpdate(
          TimelineStateEntriesCompanion.insert(
            feedKey: feed.value,
            sinceToken: Value(since),
            olderPageToken: Value(olderPageToken ?? old?.olderPageToken ?? ''),
            updatedAt: DateTime.now(),
          ),
        );
  }

  Future<Set<String>> _postIds(FeedKey feed) async {
    final rows =
        await (_db.select(_db.timelineItemEntries)..where(
              (t) => t.feedKey.equals(feed.value) & t.payload.isNotNull(),
            ))
            .get();
    return {for (final r in rows) r.itemKey};
  }

  Future<void> _upsertPosts(FeedKey feed, List<pb.PostView> views) async {
    if (views.isEmpty) return;
    await _db.batch((b) {
      b.insertAllOnConflictUpdate(_db.timelineItemEntries, [
        for (final v in views)
          TimelineItemEntriesCompanion.insert(
            feedKey: feed.value,
            itemKey: v.post.postId,
            sortKey: v.post.postId,
            payload: Value(Uint8List.fromList(v.writeToBuffer())),
          ),
      ]);
    });
  }

  Future<void> _putGap(FeedKey feed, String sortKey, String token) {
    return _db
        .into(_db.timelineItemEntries)
        .insertOnConflictUpdate(
          TimelineItemEntriesCompanion.insert(
            feedKey: feed.value,
            itemKey: 'gap:$sortKey',
            sortKey: sortKey,
            gapToken: Value(token),
          ),
        );
  }

  Future<void> _deleteItem(FeedKey feed, String itemKey) {
    return (_db.delete(_db.timelineItemEntries)..where(
          (t) => t.feedKey.equals(feed.value) & t.itemKey.equals(itemKey),
        ))
        .go();
  }

  Future<void> _deleteFeedRows(FeedKey feed) {
    return (_db.delete(
      _db.timelineItemEntries,
    )..where((t) => t.feedKey.equals(feed.value))).go();
  }

  /// Keeps the newest [kTimelineRetention] posts. When anything is dropped
  /// the scroll token is cleared: it pointed below the oldest *fetched*
  /// post, so keeping it would leave a hole between the trimmed tail and
  /// the next page.
  Future<void> _prune(FeedKey feed) async {
    final boundary =
        await (_db.select(_db.timelineItemEntries)
              ..where(
                (t) => t.feedKey.equals(feed.value) & t.payload.isNotNull(),
              )
              ..orderBy([(t) => OrderingTerm.desc(t.sortKey)])
              ..limit(1, offset: kTimelineRetention - 1))
            .getSingleOrNull();
    if (boundary == null) return;
    final removed =
        await (_db.delete(_db.timelineItemEntries)..where(
              (t) =>
                  t.feedKey.equals(feed.value) &
                  t.sortKey.isSmallerThanValue(boundary.sortKey),
            ))
            .go();
    if (removed > 0) await _saveState(feed, olderPageToken: '');
  }
}
