import 'package:flutter_bloc/flutter_bloc.dart';

import '../../data/search_repository.dart';
import '../../domain/explore_media.dart';
import 'explore_media_state.dart';

/// Posts asked per `ExploreMedia` call.
const kTrendingMediaPageSize = 20;

/// Calls one [TrendingMediaCubit.loadMore] may make: a short or empty page
/// with a token is followed, but never without end.
const kTrendingMediaMaxCallsPerMore = 3;

/// New tiles a [TrendingMediaCubit.loadMore] stops at.
const kTrendingMediaWantedPerMore = 12;

/// The global media feed of the Trending page: the newest photos of every
/// public author, paged by `ExploreMedia` tokens. The state is the same
/// [ExploreMediaState] the Explore per-hashtag media uses.
///
/// - **Cost.** [start] asks once and is a no-op afterwards. [loadMore]
///   follows the token, up to [kTrendingMediaMaxCallsPerMore] calls per scroll.
/// - Failures: `unavailable` when `search` or `trending_media` is off for the
///   caller (nothing is asked again); `failed` when the first page fails
///   ([retry] asks again); a later page failure keeps the tiles and sets
///   `pagingFailed` ([retryMore]).
class TrendingMediaCubit extends Cubit<ExploreMediaState> {
  TrendingMediaCubit({
    required SearchRepository repository,
    this.pageSize = kTrendingMediaPageSize,
  }) : _repository = repository,
       super(const ExploreMediaState());

  final SearchRepository _repository;
  final int pageSize;

  bool _started = false;
  bool _busy = false;
  String? _token;
  final List<List<PostView>> _pages = [];

  /// Asks the first page, once.
  Future<void> start() async {
    if (_started) return;
    _started = true;
    emit(const ExploreMediaState(status: ExploreMediaStatus.loading));
    try {
      final page = await _repository.exploreMedia(pageSize: pageSize);
      if (isClosed) return;
      _take(page);
      // A first page can be empty (its rows were dropped) with a token: follow
      // it a bounded number of times, so the list never starts blank for no reason.
      var calls = 1;
      while (mergeMediaTiles(_pages).isEmpty &&
          _token != null &&
          calls < kTrendingMediaMaxCallsPerMore) {
        final next = await _repository.exploreMedia(
          pageToken: _token,
          pageSize: pageSize,
        );
        if (isClosed) return;
        calls++;
        _take(next);
      }
      emit(_ready());
    } catch (error) {
      if (isClosed) return;
      emit(_failed(error));
    }
  }

  void _take(SearchPostsPage page) {
    _pages.add([...page.posts]);
    _token = page.nextPageToken;
  }

  ExploreMediaState _ready({bool pagingFailed = false, Object? error}) =>
      ExploreMediaState(
        status: ExploreMediaStatus.ready,
        tiles: mergeMediaTiles(_pages),
        hasMore: _token != null,
        pagingFailed: pagingFailed,
        error: error,
      );

  ExploreMediaState _failed(Object error) {
    if (error is SearchUnavailableException) {
      return const ExploreMediaState(status: ExploreMediaStatus.unavailable);
    }
    return ExploreMediaState(status: ExploreMediaStatus.failed, error: error);
  }

  /// The next pages, near the end of the list. Stops at
  /// [kTrendingMediaWantedPerMore] new tiles, the call bound, a failure or the
  /// end of the feed.
  Future<void> loadMore() async {
    if (_busy ||
        state.status != ExploreMediaStatus.ready ||
        _token == null ||
        state.pagingFailed) {
      return;
    }
    _busy = true;
    emit(state.copyWith(loadingMore: true));
    final before = state.tiles.length;
    var calls = 0;
    Object? failure;
    try {
      while (_token != null &&
          calls < kTrendingMediaMaxCallsPerMore &&
          mergeMediaTiles(_pages).length - before <
              kTrendingMediaWantedPerMore) {
        try {
          final page = await _repository.exploreMedia(
            pageToken: _token,
            pageSize: pageSize,
          );
          if (isClosed) return;
          calls++;
          _take(page);
        } catch (error) {
          failure = error;
          break;
        }
      }
    } finally {
      _busy = false;
    }
    if (isClosed) return;
    emit(_ready(pagingFailed: failure != null, error: failure));
  }

  /// The failed later page again.
  Future<void> retryMore() async {
    if (!state.pagingFailed) return;
    emit(state.copyWith(pagingFailed: false, error: null));
    await loadMore();
  }

  /// The first page again after a total failure.
  Future<void> retry() async {
    if (state.status != ExploreMediaStatus.failed) return;
    _started = false;
    _pages.clear();
    _token = null;
    await start();
  }
}
