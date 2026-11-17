import '../../data/search_repository.dart';
import 'trending_feed_state.dart';
import 'trending_paged_cubit.dart';

/// Posts asked per call.
const kTrendingPostsPageSize = 20;

/// Calls one more may make (a short or empty page with a token is followed,
/// never without end).
const kTrendingPostsMaxCallsPerMore = 3;

/// New posts a [TrendingFeedCubit.loadMore] stops at.
const kTrendingPostsWantedPerMore = 10;

/// The Posts section of the Trending tab: the newest public posts of every
/// author (`ExplorePosts`), or, with a [tag], the newest posts of that hashtag
/// (`SearchPosts` LATEST `#tag`; TOP has no token). Paging, stall and token
/// rules are [PagedTrendingCubit]'s.
class TrendingFeedCubit extends PagedTrendingCubit<TrendingFeedState> {
  TrendingFeedCubit({
    required SearchRepository repository,
    this.tag,
    this.pageSize = kTrendingPostsPageSize,
  }) : _repository = repository,
       super(
         const TrendingFeedState(),
         maxCalls: kTrendingPostsMaxCallsPerMore,
         wantedPerMore: kTrendingPostsWantedPerMore,
       );

  /// The hashtag (no `#`) this list is filtered to; null = everyone's posts.
  final String? tag;
  final int pageSize;
  final SearchRepository _repository;
  final Set<String> _hiddenAuthors = {};
  final Set<String> _removed = {};

  @override
  Future<SearchPostsPage> fetchPage(String? token) => tag == null
      ? _repository.explorePosts(pageToken: token, pageSize: pageSize)
      : _repository.searchPosts(
          '#$tag',
          tab: SearchTab.SEARCH_TAB_LATEST,
          pageToken: token,
          pageSize: pageSize,
        );

  List<PostView> _rows(List<List<PostView>> pages) {
    final seen = <String>{};
    final rows = <PostView>[];
    for (final page in pages) {
      for (final view in page) {
        if (!view.hasPost()) continue;
        final post = view.post;
        if (_removed.contains(post.postId) ||
            _hiddenAuthors.contains(post.author.userId) ||
            (post.hasEmbedded() &&
                _hiddenAuthors.contains(post.embedded.author.userId))) {
          continue;
        }
        if (seen.add(post.postId)) rows.add(view);
      }
    }
    return rows;
  }

  @override
  int visibleCount(List<List<PostView>> pages) => _rows(pages).length;

  @override
  TrendingFeedState buildState(
    PagedSnapshot s,
    List<List<PostView>> pages,
  ) => TrendingFeedState(
    status: s.status,
    rows: _rows(pages),
    refreshing: s.refreshing,
    loadingMore: s.loadingMore,
    pagingFailed: s.pagingFailed,
    stalled: s.stalled,
    hasMore: s.hasMore,
    notice: s.notice,
    error: s.error,
    resetSerial: s.resetSerial,
  );

  /// The caller blocked or muted [userId]: their rows leave at once.
  void hideAuthor(String userId) {
    if (_hiddenAuthors.add(userId)) reemit();
  }

  /// The caller unblocked or unmuted [userId]: their rows return.
  void restoreAuthor(String userId) {
    if (_hiddenAuthors.remove(userId)) reemit();
  }

  /// The caller deleted [postId]: the row leaves (no refetch).
  void removePost(String postId) {
    if (_removed.add(postId)) reemit();
  }

  /// A delete failed: the row returns.
  void restorePost(String postId) {
    if (_removed.remove(postId)) reemit();
  }
}
