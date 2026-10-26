import 'dart:async';

import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/network/app_exception.dart';
import '../../../../gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import '../../data/bookmarks_repository.dart';
import '../../domain/bookmark_entry.dart';
import '../../domain/engagement_entry.dart' show engagementTargetId;
import 'bookmarks_list_state.dart';

/// The rows of the Bookmarks screen (plan W2-7, ADR-0023 D2): live posts,
/// newest bookmark first, in session memory only (no drift table; a later
/// offline cache replaces this class's source and no caller).
///
/// - **Fresh on every open.** The screen creates one per visit and calls
///   [load]: page 1 replaces whatever was there (no merge, no `since` token,
///   no caching). 1 `ListBookmarks` per open plus one per scroll page.
/// - **Short pages.** The server drops hidden, blocked and missing posts, so a
///   page may hold fewer rows than asked, or none, while `next_page_token` is
///   not empty. Only an empty token ends the list: a page that adds no row
///   is followed at once ([load], [loadMore]), and the screen asks again when
///   the rows do not fill it.
/// - **Un-bookmarking** is read from the session overlay
///   ([BookmarksRepository]), which the post card's bookmark icon drives: the
///   row leaves at once ([BookmarksListState.hidden], one-shot
///   [BookmarksListState.removal] for the Undo snackbar) and comes back by
///   itself if the removal is rolled back or Undo re-adds it. A failure of
///   either is reported once ([BookmarksListState.failure]).
/// - **Sign-out.** The rows are dropped when the repository's session ends
///   (`BookmarksCubit.reset`, the shared `SessionEpoch`), and a page that
///   lands afterwards is ignored.
/// - A failed refresh or next page keeps the rows under a banner; a failed
///   next page stops automatic paging until [retry] (each try costs reads).
///   FEATURE_DISABLED (bookmarks off for everyone) is the error status with
///   that exception: the screen words it as "not available", no Retry.
class BookmarksListCubit extends Cubit<BookmarksListState> {
  BookmarksListCubit({
    required BookmarksRepository repository,
    this.pageSize = 20,
    bool? Function(pb.PostView view) serverStateOf = serverBookmarkedOf,
    void Function(Object error, StackTrace stack)? onUnexpectedError,
  }) : _repository = repository,
       _serverStateOf = serverStateOf,
       _onUnexpectedError = onUnexpectedError,
       _seenSession = repository.sessionGeneration,
       super(const BookmarksListState()) {
    _sub = repository.events.listen(_onEvent);
  }

  final BookmarksRepository _repository;

  /// The row flag the card toggles from (Undo acts like the card).
  final bool? Function(pb.PostView view) _serverStateOf;
  final void Function(Object error, StackTrace stack)? _onUnexpectedError;
  final int pageSize;
  late final StreamSubscription<BookmarkEvent> _sub;

  /// The repository's session when the rows on screen were asked for.
  int _seenSession;

  /// Bumped when a new load starts or the session ends: an answer that comes
  /// back under an older value is ignored.
  int _round = 0;
  int _serial = 0;
  bool _refreshing = false;
  bool _loadingMore = false;
  bool _pagingHalted = false;
  bool _noticeFromPaging = false;

  /// Targets whose Undo is running.
  final Set<String> _restoring = {};

  /// The last failure of the banner was a next page: [retry] asks for it
  /// again, and the screen shows it at the end of the list.
  bool get noticeFromPaging => _noticeFromPaging;

  /// The first page, with the skeleton (also the error view's Retry).
  Future<void> load() async {
    _round++;
    _refreshing = false;
    _loadingMore = false;
    _pagingHalted = false;
    _noticeFromPaging = false;
    emit(const BookmarksListState());
    await refresh();
  }

  /// Reloads page 1, keeping the rows on screen (pull to refresh).
  Future<void> refresh() async {
    if (_refreshing) return;
    _refreshing = true;
    final round = _round;
    _seenSession = _repository.sessionGeneration;
    try {
      final result = await _fetch(token: '');
      if (isClosed || round != _round) return;
      if (result == null) return _sessionEnded();
      _noticeFromPaging = false;
      _pagingHalted = false;
      emit(
        BookmarksListState(
          status: BookmarksListStatus.ready,
          items: result.items,
          nextPageToken: result.token,
          hidden: _hiddenIds(result.items),
          // A removal / failure not yet shown stays pending.
          removal: state.removal,
          failure: state.failure,
        ),
      );
    } on AppException catch (e) {
      if (isClosed || round != _round) return;
      _noticeFromPaging = false;
      _failedLoad(e);
    } catch (error, stack) {
      _onUnexpectedError?.call(error, stack);
      if (isClosed || round != _round) return;
      _noticeFromPaging = false;
      _failedLoad(const UnknownApiException('Something went wrong.'));
    } finally {
      if (round == _round) _refreshing = false;
    }
  }

  void _failedLoad(AppException error) {
    if (error is FeatureDisabledException || state.items.isEmpty) {
      emit(BookmarksListState(status: BookmarksListStatus.error, error: error));
    } else {
      emit(state.copyWith(notice: error));
    }
  }

  /// The next page, once the user is near the end (or the rows do not fill
  /// the screen). Guarded against concurrent calls; a failure keeps the rows,
  /// sets the banner and halts automatic paging until [retry].
  Future<void> loadMore() async {
    if (_loadingMore ||
        _refreshing ||
        _pagingHalted ||
        !state.hasMore ||
        state.status != BookmarksListStatus.ready) {
      return;
    }
    _loadingMore = true;
    final round = _round;
    emit(
      state.copyWith(
        status: BookmarksListStatus.loadingMore,
        clearNotice: true,
      ),
    );
    try {
      final result = await _fetch(
        token: state.nextPageToken,
        known: state.items,
      );
      if (isClosed || round != _round) return;
      if (result == null) return _sessionEnded();
      final items = [...state.items, ...result.items];
      emit(
        state.copyWith(
          status: BookmarksListStatus.ready,
          items: items,
          nextPageToken: result.token,
          hidden: _hiddenIds(items),
        ),
      );
    } on AppException catch (e) {
      _pagingFailed(round, e);
    } catch (error, stack) {
      _onUnexpectedError?.call(error, stack);
      _pagingFailed(round, const UnknownApiException('Something went wrong.'));
    } finally {
      if (round == _round) _loadingMore = false;
    }
  }

  void _pagingFailed(int round, AppException error) {
    if (isClosed || round != _round) return;
    if (error is FeatureDisabledException) {
      return _failedLoad(error);
    }
    _pagingHalted = true;
    _noticeFromPaging = true;
    emit(state.copyWith(status: BookmarksListStatus.ready, notice: error));
  }

  /// The banner's Retry: the failed page again, or a refresh.
  Future<void> retry() {
    if (!_noticeFromPaging) return refresh();
    _pagingHalted = false;
    return loadMore();
  }

  /// Undo of a removal: bookmarks [view]'s post again (through the
  /// repository, like the card's icon). The row comes back at its place.
  Future<void> restore(pb.PostView view) async {
    final id = engagementTargetId(view.post);
    // A rolled-back Undo is not a new removal: no second Undo snackbar.
    _restoring.add(id);
    try {
      await _repository.setBookmarked(
        id,
        saved: true,
        server: _serverStateOf(view),
      );
    } finally {
      _restoring.remove(id);
    }
  }

  /// The Undo snackbar was shown; clears it.
  void removalShown() {
    if (!isClosed && state.removal != null) {
      emit(state.copyWith(clearRemoval: true));
    }
  }

  /// The failure was shown; clears it.
  void failureShown() {
    if (!isClosed && state.failure != null) {
      emit(state.copyWith(clearFailure: true));
    }
  }

  /// One request round: asks for [token] and keeps following the token while
  /// the pages bring no row the screen does not already have ([known]) -
  /// the server drops what the viewer may not see, so an empty page with a
  /// token is normal. Null: the session ended meanwhile.
  Future<({List<pb.PostView> items, String token})?> _fetch({
    required String token,
    List<pb.PostView> known = const [],
  }) async {
    final seen = {for (final v in known) engagementTargetId(v.post)};
    final fresh = <pb.PostView>[];
    var next = token;
    while (true) {
      final page = await _repository.listBookmarks(
        pageToken: next,
        pageSize: pageSize,
      );
      if (page == null) return null;
      for (final bookmark in page.bookmarks) {
        final view = bookmark.post;
        final id = engagementTargetId(view.post);
        if (id.isEmpty || !seen.add(id)) continue;
        fresh.add(view);
      }
      final following = page.nextPageToken;
      // Stop on a row, on the end, or on a token that did not advance.
      if (fresh.isNotEmpty || following.isEmpty || following == next) {
        return (items: fresh, token: following);
      }
      next = following;
    }
  }

  void _onEvent(BookmarkEvent event) {
    if (isClosed) return;
    switch (event) {
      case BookmarksChanged():
        if (_repository.sessionGeneration != _seenSession) {
          _sessionEnded();
        } else {
          _syncHidden();
        }
      case BookmarkFailed(:final postId, :final wanted, :final error):
        if (state.items.any((v) => engagementTargetId(v.post) == postId)) {
          emit(
            state.copyWith(
              failure: BookmarkListFailure(
                postId: postId,
                saving: wanted,
                error: error,
                serial: ++_serial,
              ),
            ),
          );
        }
      case BookmarkSettled():
        break;
    }
  }

  /// Sign-out: nothing of the previous user stays, and any request still in
  /// flight is ignored when it lands.
  void _sessionEnded() {
    _round++;
    _refreshing = false;
    _loadingMore = false;
    _pagingHalted = false;
    _noticeFromPaging = false;
    _seenSession = _repository.sessionGeneration;
    emit(const BookmarksListState());
  }

  /// Rows whose bookmark the overlay says is gone leave the list; a row that
  /// just left raises the one-shot [BookmarksListState.removal].
  void _syncHidden() {
    final hidden = _hiddenIds(state.items);
    if (setEquals(hidden, state.hidden)) return;
    final left = hidden.difference(state.hidden);
    pb.PostView? removed;
    for (final view in state.items) {
      final id = engagementTargetId(view.post);
      if (left.contains(id) && !_restoring.contains(id)) removed = view;
    }
    emit(
      state.copyWith(
        hidden: hidden,
        removal: removed == null
            ? null
            : BookmarkRemoval(view: removed, serial: ++_serial),
      ),
    );
  }

  /// The server flag of a row is deliberately not consulted: a listed row is
  /// bookmarked by definition (the page recorded it in the local set), also
  /// for a caller whose `userLikes` hydration is off, and only the session
  /// overlay can take it away.
  Set<String> _hiddenIds(List<pb.PostView> items) => {
    for (final view in items)
      if (!_repository.isBookmarked(engagementTargetId(view.post)))
        engagementTargetId(view.post),
  };

  @override
  Future<void> close() async {
    await _sub.cancel();
    return super.close();
  }
}
