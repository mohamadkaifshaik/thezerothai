import '../../data/search_repository.dart';
import '../../domain/explore_media.dart';
import 'explore_media_state.dart';
import 'trending_paged_cubit.dart';

/// Posts asked per `ExploreMedia` call.
const kTrendingMediaPageSize = 20;

/// Calls one [TrendingMediaCubit.loadMore] may make: a short or empty page
/// with a token is followed, but never without end.
const kTrendingMediaMaxCallsPerMore = 3;

/// New tiles a [TrendingMediaCubit.loadMore] stops at.
const kTrendingMediaWantedPerMore = 12;

/// The media feed of the Trending page: the newest photos of every public
/// author (`ExploreMedia`), or, with a [tag], the newest photos of that
/// hashtag (`SearchPosts` MEDIA `#tag`), paged by tokens. The state is the same
/// [ExploreMediaState] the Explore per-hashtag media uses. Paging, stall and
/// token rules are [PagedTrendingCubit]'s.
///
/// - **Cost.** [start] asks once and is a no-op afterwards; [loadMore] follows
///   the token, up to [kTrendingMediaMaxCallsPerMore] calls per scroll.
/// - Failures: `unavailable` when the feature is off for the caller (nothing
///   is asked again); `failed` when the first page fails ([retry]); a later
///   page failure keeps the tiles and sets `pagingFailed` ([retryMore]).
class TrendingMediaCubit extends PagedTrendingCubit<ExploreMediaState> {
  TrendingMediaCubit({
    required SearchRepository repository,
    this.pageSize = kTrendingMediaPageSize,
    this.tag,
  }) : _repository = repository,
       super(
         const ExploreMediaState(),
         maxCalls: kTrendingMediaMaxCallsPerMore,
         wantedPerMore: kTrendingMediaWantedPerMore,
       );

  final SearchRepository _repository;
  final int pageSize;

  /// The hashtag (no `#`) this grid is filtered to; null = everyone's photos.
  final String? tag;

  @override
  Future<SearchPostsPage> fetchPage(String? token) => tag == null
      ? _repository.exploreMedia(pageToken: token, pageSize: pageSize)
      : _repository.searchPosts(
          '#$tag',
          tab: SearchTab.SEARCH_TAB_MEDIA,
          pageToken: token,
          pageSize: pageSize,
        );

  @override
  int visibleCount(List<List<PostView>> pages) =>
      mergeMediaTiles(pages).length;

  @override
  ExploreMediaState buildState(
    PagedSnapshot s,
    List<List<PostView>> pages,
  ) => ExploreMediaState(
    status: switch (s.status) {
      PagedStatus.initial => ExploreMediaStatus.initial,
      PagedStatus.loading => ExploreMediaStatus.loading,
      PagedStatus.ready => ExploreMediaStatus.ready,
      PagedStatus.failed => ExploreMediaStatus.failed,
      PagedStatus.unavailable => ExploreMediaStatus.unavailable,
    },
    tiles: mergeMediaTiles(pages),
    loadingMore: s.loadingMore,
    hasMore: s.hasMore,
    pagingFailed: s.pagingFailed,
    error: s.error,
    refreshing: s.refreshing,
    stalled: s.stalled,
    notice: s.notice,
    resetSerial: s.resetSerial,
  );
}
