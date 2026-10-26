import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import '../../data/bookmarks_repository.dart';
import '../../domain/bookmark_entry.dart';
import 'bookmarks_state.dart';

/// The session-wide bookmark overlay for widgets (plan W2-6, ADR-0023): a
/// thin mirror of [BookmarksRepository], which owns the logic (optimistic
/// toggle, rollback, one idempotency key per intent, per-post serialisation,
/// session reset). Every card of the same target, and the W2-7 screen, read
/// the same entry, so a bookmark shows everywhere at once.
///
/// - [isBookmarked] / [setBookmarked] take the feed row: the target is the
///   original for a REPOST row (the caller passes `engagementTargetId`) and
///   the row's own server flag is read through [serverStateOf] (default
///   [serverBookmarkedOf], the single W2-1b hook).
/// - [viewRoute] is where the "View" action of the "Added to Bookmarks" toast
///   goes; null (until W2-7 registers `/bookmarks`) means the toast has no
///   View action.
/// - [reset] (sign-out) forgets everything.
class BookmarksCubit extends Cubit<BookmarksState> {
  BookmarksCubit({
    required BookmarksRepository repository,
    this.viewRoute,
    bool? Function(pb.PostView view) serverStateOf = serverBookmarkedOf,
  }) : _repository = repository,
       _serverStateOf = serverStateOf,
       super(const BookmarksState()) {
    _sub = repository.events.listen(_onEvent);
  }

  final BookmarksRepository _repository;
  final bool? Function(pb.PostView view) _serverStateOf;
  late final StreamSubscription<BookmarkEvent> _sub;
  int _serial = 0;

  /// The route the toast's "View" action opens, or null for no action.
  final String? viewRoute;

  /// The server's own flag of [view], or null when the row has none.
  bool? serverStateOf(pb.PostView view) => _serverStateOf(view);

  /// Whether the post [targetId] of [view] is bookmarked.
  bool isBookmarked(String targetId, pb.PostView view) =>
      state.entries[targetId]?.resolve(serverStateOf(view)) ??
      serverStateOf(view) ??
      false;

  /// Bookmarks ([saved] true) or removes [targetId].
  Future<void> setBookmarked(
    String targetId,
    pb.PostView view, {
    required bool saved,
  }) => _repository.setBookmarked(
    targetId,
    saved: saved,
    server: serverStateOf(view),
  );

  /// The failure was shown; clears it.
  void failureShown() {
    if (!isClosed && state.failure != null) {
      emit(state.copyWith(clearFailure: true));
    }
  }

  /// The toast was shown; clears it.
  void noticeShown() {
    if (!isClosed && state.notice != null) {
      emit(state.copyWith(clearNotice: true));
    }
  }

  /// Sign-out: forget every entry and queued intent.
  void reset() {
    _repository.clearSession();
    if (!isClosed) emit(const BookmarksState());
  }

  void _onEvent(BookmarkEvent event) {
    if (isClosed) return;
    switch (event) {
      case BookmarksChanged():
        emit(state.copyWith(entries: _repository.snapshot()));
      case BookmarkFailed():
        emit(
          state.copyWith(
            failure: BookmarkFailure(
              postId: event.postId,
              saving: event.wanted,
              error: event.error,
              serial: ++_serial,
            ),
          ),
        );
      case BookmarkSettled():
        emit(
          state.copyWith(
            notice: BookmarkNotice(
              postId: event.postId,
              saved: event.saved,
              serial: ++_serial,
            ),
          ),
        );
    }
  }

  @override
  Future<void> close() async {
    await _sub.cancel();
    return super.close();
  }
}
