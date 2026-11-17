import 'package:flutter_bloc/flutter_bloc.dart';

import '../../data/search_repository.dart';

/// Where a paged Trending section is.
enum PagedStatus { initial, loading, ready, failed, unavailable }

/// What a [PagedTrendingCubit] knows besides its rows; each cubit maps it
/// (with its rows) to its own freezed state.
class PagedSnapshot {
  const PagedSnapshot({
    this.status = PagedStatus.initial,
    this.refreshing = false,
    this.loadingMore = false,
    this.pagingFailed = false,
    this.stalled = false,
    this.hasMore = false,
    this.notice,
    this.error,
    this.resetSerial = 0,
  });

  final PagedStatus status;
  final bool refreshing;
  final bool loadingMore;
  final bool pagingFailed;

  /// A round spent its calls on empty pages and a next page still exists:
  /// only the "Load more" button asks again.
  final bool stalled;
  final bool hasMore;

  /// A failed refresh with the rows kept.
  final Object? notice;
  final Object? error;

  /// Counts silent restarts after an expired page token (the view jumps to
  /// the top when it changes).
  final int resetSerial;

  /// Whether a scroll or a short list may ask for the next page by itself.
  bool get canAutoLoad =>
      status == PagedStatus.ready &&
      hasMore &&
      !loadingMore &&
      !refreshing &&
      !stalled &&
      !pagingFailed;

  PagedSnapshot copyWith({
    bool? refreshing,
    bool? loadingMore,
    bool? pagingFailed,
    bool? stalled,
    Object? notice = _keep,
    Object? error = _keep,
  }) => PagedSnapshot(
    status: status,
    refreshing: refreshing ?? this.refreshing,
    loadingMore: loadingMore ?? this.loadingMore,
    pagingFailed: pagingFailed ?? this.pagingFailed,
    stalled: stalled ?? this.stalled,
    hasMore: hasMore,
    notice: identical(notice, _keep) ? this.notice : notice,
    error: identical(error, _keep) ? this.error : error,
    resetSerial: resetSerial,
  );

  static const Object _keep = Object();
}

class _Feed {
  final List<List<PostView>> pages = [];
  String? token;
}

class _Round {
  int calls = 0;
  Object? failure;
  bool expired = false;
}

/// The paging of one Trending section (Posts or Media, untagged or for one
/// hashtag): the cost rules in one place.
///
/// - A page can be short or empty while the next-page token is set, so a round
///   follows the token, at most [maxCalls] calls, until [wantedPerMore] new
///   rows came in. A round that spent its calls on nothing is `stalled`.
/// - While stalled, after a failed page or a rate limit, nothing asks
///   by itself ([PagedSnapshot.canAutoLoad]); [continueAfterStall] and
///   [retryMore] run one more bounded round.
/// - An expired or foreign token (`page_token` validation error) restarts
///   from page one without an error.
/// - `FEATURE_DISABLED` is `unavailable` and nothing is asked again.
/// - A late answer after a refresh, a restart or close is dropped.
abstract class PagedTrendingCubit<S> extends Cubit<S> {
  PagedTrendingCubit(
    super.initialState, {
    required this.maxCalls,
    required this.wantedPerMore,
  });

  final int maxCalls;
  final int wantedPerMore;

  _Feed _feed = _Feed();
  PagedSnapshot _snap = const PagedSnapshot();
  bool _started = false;
  bool _busy = false;
  int _gen = 0;

  /// One page of the source ([token] null = the first).
  Future<SearchPostsPage> fetchPage(String? token);

  /// How many rows [pages] show (after the cubit's own filters).
  int visibleCount(List<List<PostView>> pages);

  /// The state for [snapshot] over the held pages.
  S buildState(PagedSnapshot snapshot, List<List<PostView>> pages);

  /// The paging facts the cubit's state is built from.
  PagedSnapshot get snapshot => _snap;

  /// The rows may have changed (a filter moved): emit again.
  void reemit() {
    if (!isClosed) emit(buildState(_snap, _feed.pages));
  }

  void _set(PagedSnapshot snap) {
    _snap = snap;
    reemit();
  }

  PagedSnapshot _ready(
    _Feed feed, {
    bool pagingFailed = false,
    bool stalled = false,
    Object? error,
    int? resetSerial,
  }) => PagedSnapshot(
    status: PagedStatus.ready,
    hasMore: feed.token != null,
    pagingFailed: pagingFailed,
    stalled: stalled,
    error: error,
    resetSerial: resetSerial ?? _snap.resetSerial,
  );

  /// Calls up to [maxCalls] pages into [feed]: the first when [fresh] (no
  /// token), then the token, until [wanted] new rows or the end.
  Future<_Round> _run(
    _Feed feed,
    int gen, {
    required bool fresh,
    required int wanted,
  }) async {
    final round = _Round();
    final before = visibleCount(feed.pages);
    var first = fresh;
    while ((first || feed.token != null) &&
        round.calls < maxCalls &&
        (first || visibleCount(feed.pages) - before < wanted)) {
      try {
        final page = await fetchPage(first ? null : feed.token);
        if (isClosed || gen != _gen) return round;
        round.calls++;
        feed.pages.add([...page.posts]);
        feed.token = page.nextPageToken;
        first = false;
      } catch (error) {
        if (isClosed || gen != _gen) return round;
        if (!fresh &&
            error is SearchInvalidQueryException &&
            error.field == 'page_token') {
          round.expired = true;
        } else {
          round.failure = error;
        }
        return round;
      }
    }
    return round;
  }

  bool _stalled(_Round r, _Feed feed, int before) =>
      r.failure == null &&
      !r.expired &&
      r.calls >= maxCalls &&
      feed.token != null &&
      visibleCount(feed.pages) - before <= 0;

  /// Asks the first page, once.
  Future<void> start() async {
    if (_started) return;
    _started = true;
    final gen = ++_gen;
    _feed = _Feed();
    _set(const PagedSnapshot(status: PagedStatus.loading));
    final round = await _run(_feed, gen, fresh: true, wanted: 1);
    if (isClosed || gen != _gen) return;
    final failure = round.failure;
    if (failure != null) {
      _set(
        failure is SearchUnavailableException
            ? const PagedSnapshot(status: PagedStatus.unavailable)
            : PagedSnapshot(status: PagedStatus.failed, error: failure),
      );
      return;
    }
    _set(_ready(_feed, stalled: _stalled(round, _feed, 0)));
  }

  /// The first page again after a total failure.
  Future<void> retry() async {
    if (_snap.status != PagedStatus.failed) return;
    _started = false;
    await start();
  }

  /// Near the end of the list (or a short list): the next rows. No-op while
  /// stalled, failed or busy.
  Future<void> loadMore() async {
    if (!_snap.canAutoLoad || _busy) return;
    await _advance();
  }

  /// "Load more" after a stall: one more bounded round.
  Future<void> continueAfterStall() async {
    if (!_snap.stalled || _busy || _snap.refreshing) return;
    await _advance();
  }

  /// The failed later page again.
  Future<void> retryMore() async {
    if (!_snap.pagingFailed || _busy || _snap.refreshing) return;
    await _advance();
  }

  Future<void> _advance() async {
    if (_snap.status != PagedStatus.ready || _feed.token == null) return;
    final gen = _gen;
    _busy = true;
    _set(
      _snap.copyWith(
        loadingMore: true,
        pagingFailed: false,
        stalled: false,
        error: null,
      ),
    );
    try {
      var before = visibleCount(_feed.pages);
      var round = await _run(_feed, gen, fresh: false, wanted: wantedPerMore);
      if (isClosed || gen != _gen) return;
      var serial = _snap.resetSerial;
      if (round.expired) {
        // The token is no longer good: page one, silently.
        final feed = _Feed();
        before = 0;
        round = await _run(feed, gen, fresh: true, wanted: wantedPerMore);
        if (isClosed || gen != _gen) return;
        if (round.failure == null) {
          _feed = feed;
          serial++;
        }
      }
      final failure = round.failure;
      if (failure is SearchUnavailableException) {
        _set(const PagedSnapshot(status: PagedStatus.unavailable));
        return;
      }
      _set(
        _ready(
          _feed,
          pagingFailed: failure != null,
          stalled: _stalled(round, _feed, before),
          error: failure,
          resetSerial: serial,
        ),
      );
    } finally {
      _busy = false;
    }
  }

  /// Pull to refresh: page one again; the rows stay while it is on its way and
  /// when it fails (then [PagedSnapshot.notice] says so).
  Future<void> refresh() async {
    switch (_snap.status) {
      case PagedStatus.failed:
        return retry();
      case PagedStatus.initial:
        return start();
      case PagedStatus.loading:
      case PagedStatus.unavailable:
        return;
      case PagedStatus.ready:
        break;
    }
    if (_snap.refreshing) return;
    final gen = ++_gen;
    _busy = false;
    _set(_snap.copyWith(refreshing: true, loadingMore: false, notice: null));
    final fresh = _Feed();
    final round = await _run(fresh, gen, fresh: true, wanted: 1);
    if (isClosed || gen != _gen) return;
    final failure = round.failure;
    if (failure is SearchUnavailableException) {
      _set(const PagedSnapshot(status: PagedStatus.unavailable));
      return;
    }
    if (failure != null) {
      _set(_snap.copyWith(refreshing: false, notice: failure));
      return;
    }
    _feed = fresh;
    _set(_ready(fresh, stalled: _stalled(round, fresh, 0)));
  }
}
