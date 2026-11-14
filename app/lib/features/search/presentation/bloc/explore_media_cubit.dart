import 'package:flutter_bloc/flutter_bloc.dart';

import '../../data/search_repository.dart';
import '../../domain/explore_media.dart';
import 'explore_media_state.dart';

/// Posts asked per hashtag per call.
const kExploreMediaPageSize = 20;

/// Calls one [ExploreMediaCubit.loadMore] may make (empty MEDIA pages with a
/// token are followed, but never without end): two rounds over the top tags.
const kExploreMediaMaxCallsPerMore = 2 * kExploreTopTrends;

/// New tiles a [ExploreMediaCubit.loadMore] stops at.
const kExploreMediaWantedPerMore = 9;

/// The photos of the top trending hashtags, newest first: one MEDIA
/// `SearchPosts` per tag, merged and de-duplicated by post id.
///
/// - **Cost.** [start] asks once (first page of each tag, in parallel: 3
///   calls) and is a no-op afterwards, so a rebuild or a refreshed trends
///   list never asks again. [loadMore] (the See all page) follows each tag's
///   `next_page_token`; MEDIA pages can be short or empty while the token is
///   set, so it keeps following them, up to [kExploreMediaMaxCallsPerMore]
///   calls per scroll.
/// - A tag whose call fails is skipped; the section hides when nothing came.
class ExploreMediaCubit extends Cubit<ExploreMediaState> {
  ExploreMediaCubit({
    required SearchRepository repository,
    this.pageSize = kExploreMediaPageSize,
  }) : _repository = repository,
       super(const ExploreMediaState());

  final SearchRepository _repository;
  final int pageSize;

  bool _started = false;
  bool _busy = false;
  List<String> _tags = const [];
  final Map<String, List<PostView>> _posts = {};
  final Map<String, String> _tokens = {};

  /// Asks the first page of each of [tags] (bare tags, no `#`), once.
  Future<void> start(List<String> tags) async {
    if (_started || tags.isEmpty) return;
    _started = true;
    _tags = tags.take(kExploreTopTrends).toList();
    emit(const ExploreMediaState(status: ExploreMediaStatus.loading));
    Object? firstError;
    var ok = 0;
    var unavailable = false;
    await Future.wait([
      for (final tag in _tags)
        _repository
            .searchPosts(
              '#$tag',
              tab: SearchTab.SEARCH_TAB_MEDIA,
              pageSize: pageSize,
            )
            .then<void>((page) {
              ok++;
              _posts[tag] = [...page.posts];
              final token = page.nextPageToken;
              if (token != null) _tokens[tag] = token;
            })
            .catchError((Object error) {
              firstError ??= error;
              if (error is SearchUnavailableException) unavailable = true;
            }),
    ]);
    if (isClosed) return;
    if (unavailable) {
      emit(const ExploreMediaState(status: ExploreMediaStatus.unavailable));
    } else if (ok == 0) {
      emit(
        ExploreMediaState(status: ExploreMediaStatus.failed, error: firstError),
      );
    } else {
      emit(_ready());
    }
  }

  ExploreMediaState _ready({bool pagingFailed = false, Object? error}) =>
      ExploreMediaState(
        status: ExploreMediaStatus.ready,
        tiles: mergeMediaTiles(_posts.values),
        hasMore: _tokens.isNotEmpty,
        pagingFailed: pagingFailed,
        error: error,
      );

  /// The next pages, on a scroll near the end. Follows tokens (also past
  /// empty pages) until [kExploreMediaWantedPerMore] new tiles arrived, the
  /// call bound is spent, or no token is left.
  Future<void> loadMore() async {
    if (_busy ||
        state.status != ExploreMediaStatus.ready ||
        _tokens.isEmpty ||
        state.pagingFailed) {
      return;
    }
    _busy = true;
    emit(state.copyWith(loadingMore: true));
    final before = state.tiles.length;
    var calls = 0;
    Object? failure;
    try {
      while (_tokens.isNotEmpty &&
          calls < kExploreMediaMaxCallsPerMore &&
          mergeMediaTiles(_posts.values).length - before <
              kExploreMediaWantedPerMore) {
        final round = [
          for (final tag in _tags)
            if (_tokens.containsKey(tag)) tag,
        ];
        await Future.wait([
          for (final tag in round)
            _repository
                .searchPosts(
                  '#$tag',
                  tab: SearchTab.SEARCH_TAB_MEDIA,
                  pageToken: _tokens[tag],
                  pageSize: pageSize,
                )
                .then<void>((page) {
                  (_posts[tag] ??= []).addAll(page.posts);
                  final token = page.nextPageToken;
                  if (token == null) {
                    _tokens.remove(tag);
                  } else {
                    _tokens[tag] = token;
                  }
                })
                .catchError((Object error) {
                  failure ??= error;
                }),
        ]);
        calls += round.length;
        if (failure != null) break;
      }
    } finally {
      _busy = false;
    }
    if (isClosed) return;
    emit(_ready(pagingFailed: failure != null, error: failure));
  }

  /// The failed page again.
  Future<void> retryMore() async {
    if (!state.pagingFailed) return;
    emit(state.copyWith(pagingFailed: false, error: null));
    await loadMore();
  }

  /// The first pages again after a total failure.
  Future<void> retry() async {
    if (state.status != ExploreMediaStatus.failed) return;
    _started = false;
    await start(_tags);
  }
}
