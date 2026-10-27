import 'dart:async';

import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/network/app_exception.dart';
import '../../../../gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import '../../data/likes_repository.dart';
import '../../domain/engagement_entry.dart'
    show EngagementEntry, engagementTargetId;
import 'engagement_cubit.dart';
import 'likes_list_state.dart';

/// The rows of the Likes tab (plan W3-18, ADR-0024 D6): live posts, most
/// recent like first, in session memory only (no drift table; a later
/// full-history source or offline cache replaces `LikesRepository`'s body and
/// no caller). The same pattern as `BookmarksListCubit`, without its Undo
/// machinery: an unlike has no Undo (the heart is the way back, from the post).
///
/// - **Fresh on every open.** The tab creates one per visit and calls [load]:
///   page 1 replaces whatever was there (no merge, no `since` token, no
///   caching). 1 `ListLikedPosts` per open plus one per scroll page.
/// - **Short pages.** The server drops hidden, blocked and missing posts and
///   never refills a page, so a page may hold fewer rows than asked, or none,
///   while `next_page_token` is not empty. Only an empty token ends the list:
///   `LikesRepository.fetchPage` follows the token through pages that add no
///   row, and the screen asks again when the rows do not fill it.
/// - **Un-liking** is read from the session's [EngagementCubit] overlay, which
///   the post card's heart drives: a row leaves at once ([LikesListState.hidden])
///   when the overlay entry that matches the row says "not liked" (the very
///   rule the card uses for the heart, so the two never disagree) and comes
///   back by itself if the unlike is rolled back. `liked_by_viewer` of a row is
///   never consulted: it is false on every row while `engagement` is off.
///   The failure of an unlike is worded by the screen, because the card of a
///   hidden row is gone.
/// - **Expired token.** `VALIDATION field=page_token` while paging drops the
///   token and loads page 1 again.
/// - **Sign-out.** The rows are dropped when the repository's session ends,
///   and a page that lands afterwards is ignored.
/// - A failed refresh or next page keeps the rows under a banner; a failed
///   next page stops automatic paging until [retry] (each try costs reads).
///   FEATURE_DISABLED (and UNIMPLEMENTED, mapped to it by the repository) is
///   the error status with that exception: the screen hides the tab.
class LikesListCubit extends Cubit<LikesListState> {
  LikesListCubit({
    required LikesRepository repository,
    required EngagementCubit engagement,
    this.pageSize = 20,
    void Function(Object error, StackTrace stack)? onUnexpectedError,
  }) : _onUnexpectedError = onUnexpectedError,
       _repository = repository,
       _engagement = engagement,
       _seenSession = repository.sessionGeneration,
       super(const LikesListState()) {
    _engagementSub = engagement.stream.listen((_) => _onEngagement());
    _sessionSub = repository.sessionEnds.listen((_) => _sessionEnded());
  }

  final LikesRepository _repository;
  final EngagementCubit _engagement;
  final int pageSize;
  final void Function(Object error, StackTrace stack)? _onUnexpectedError;
  late final StreamSubscription<Object?> _engagementSub;
  late final StreamSubscription<void> _sessionSub;

  /// The repository's session when the rows on screen were asked for.
  int _seenSession;

  /// Bumped when a new load starts or the session ends: an answer that comes
  /// back under an older value is ignored.
  int _round = 0;
  bool _refreshing = false;
  bool _loadingMore = false;
  bool _pagingHalted = false;
  bool _noticeFromPaging = false;

  /// The last failure of the banner was a next page: [retry] asks for it
  /// again, and the screen shows it at the end of the list.
  bool get noticeFromPaging => _noticeFromPaging;

  /// Whether the loaded pages hold the post [postId].
  bool holds(String postId) =>
      state.items.any((view) => engagementTargetId(view.post) == postId);

  /// The first page, with the skeleton (also the error view's Retry).
  Future<void> load() async {
    _round++;
    _refreshing = false;
    _loadingMore = false;
    _pagingHalted = false;
    _noticeFromPaging = false;
    emit(const LikesListState());
    await refresh();
  }

  /// Reloads page 1, keeping the rows on screen (pull to refresh).
  Future<void> refresh() async {
    if (_refreshing) return;
    _refreshing = true;
    final round = _round;
    _seenSession = _repository.sessionGeneration;
    try {
      final page = await _repository.fetchPage(pageSize: pageSize);
      if (isClosed || round != _round) return;
      if (page == null) return _sessionEnded();
      _noticeFromPaging = false;
      _pagingHalted = false;
      emit(
        LikesListState(
          status: LikesListStatus.ready,
          items: page.posts,
          nextPageToken: page.nextPageToken,
          hidden: _hiddenIds(page.posts),
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
      emit(LikesListState(status: LikesListStatus.error, error: error));
    } else {
      emit(state.copyWith(status: LikesListStatus.ready, notice: error));
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
        state.status != LikesListStatus.ready) {
      return;
    }
    _loadingMore = true;
    final round = _round;
    emit(
      state.copyWith(status: LikesListStatus.loadingMore, clearNotice: true),
    );
    try {
      final page = await _repository.fetchPage(
        after: state.nextPageToken,
        known: {for (final view in state.items) engagementTargetId(view.post)},
        pageSize: pageSize,
      );
      if (isClosed || round != _round) return;
      if (page == null) return _sessionEnded();
      final items = [...state.items, ...page.posts];
      emit(
        state.copyWith(
          status: LikesListStatus.ready,
          items: items,
          nextPageToken: page.nextPageToken,
          hidden: _hiddenIds(items),
        ),
      );
    } on ValidationException catch (e) {
      if (isClosed || round != _round) return;
      if (e.field == 'page_token') {
        // The token expired (24 h) or is not ours: drop it, start again.
        emit(state.copyWith(status: LikesListStatus.ready, clearNotice: true));
        await refresh();
      } else {
        _pagingFailed(round, e);
      }
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
    emit(state.copyWith(status: LikesListStatus.ready, notice: error));
  }

  /// The banner's Retry: the failed page again, or a refresh.
  Future<void> retry() {
    if (!_noticeFromPaging) return refresh();
    _pagingHalted = false;
    return loadMore();
  }

  void _onEngagement() {
    if (isClosed) return;
    if (_repository.sessionGeneration != _seenSession) {
      _sessionEnded();
    } else {
      _syncHidden();
    }
  }

  /// Sign-out: nothing of the previous user stays, and any request still in
  /// flight is ignored when it lands.
  void _sessionEnded() {
    if (isClosed) return;
    _round++;
    _refreshing = false;
    _loadingMore = false;
    _pagingHalted = false;
    _noticeFromPaging = false;
    _seenSession = _repository.sessionGeneration;
    emit(const LikesListState());
  }

  void _syncHidden() {
    final hidden = _hiddenIds(state.items);
    if (setEquals(hidden, state.hidden)) return;
    emit(state.copyWith(hidden: hidden));
  }

  /// Rows the overlay says the caller un-liked: the entry of the row's target
  /// still describes this row (a request runs, or the row still says what it
  /// said when the entry was made: `EngagementEntry.matches`) and is not
  /// liked. Same test as `PostEngagementBar`, so the heart and the row's
  /// presence cannot disagree.
  Set<String> _hiddenIds(List<pb.PostView> items) {
    final entries = _engagement.state.entries;
    if (entries.isEmpty) return const {};
    return {
      for (final view in items)
        if (_unliked(entries[engagementTargetId(view.post)], view))
          engagementTargetId(view.post),
    };
  }

  static bool _unliked(EngagementEntry? entry, pb.PostView view) =>
      entry != null && entry.matches(view) && !entry.liked;

  @override
  Future<void> close() async {
    await _engagementSub.cancel();
    await _sessionSub.cancel();
    return super.close();
  }
}
