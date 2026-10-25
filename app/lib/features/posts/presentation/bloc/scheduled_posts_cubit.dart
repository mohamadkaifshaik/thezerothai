import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:uuid/uuid.dart';

import '../../../../core/network/app_exception.dart';
import '../../../../gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import '../../../../gen/dzeroth/posts/v1/posts.pbenum.dart'
    show ScheduledPostStatus;
import '../../data/posts_repository.dart';
import 'scheduled_posts_state.dart';

/// How a Cancel or Dismiss ended.
enum ScheduledRemovalOutcome {
  /// The item is gone (cancelled, dismissed, or already gone).
  done,

  /// The post had already been published: too late to cancel (not an error).
  tooLate,

  /// The call failed; the row was put back.
  failed,
}

/// The result of [ScheduledPostsCubit.remove].
class ScheduledRemoval {
  const ScheduledRemoval(this.outcome, [this.error]);

  final ScheduledRemovalOutcome outcome;

  /// Set with [ScheduledRemovalOutcome.failed].
  final AppException? error;
}

/// Pages the caller's scheduled posts (CMP-D6, ADR-0021 D4) and removes rows:
/// Cancel for a PENDING item, Dismiss for a FAILED one (the same RPC).
///
/// - Only PENDING and FAILED items are shown, in the server order (oldest
///   publish time first).
/// - A failed refresh or next page keeps the rows already loaded and raises
///   [ScheduledPostsState.notice]; only a failed first page is an error view.
/// - [remove] is optimistic: the row leaves at once and comes back if the
///   call fails. An item that turned PUBLISHED or CANCELLED meanwhile (or no
///   longer exists) counts as done.
/// - Nothing is cached on disk and nothing polls: one `ListScheduledPosts`
///   (1 + page reads) per open, refresh or page.
class ScheduledPostsCubit extends Cubit<ScheduledPostsState> {
  ScheduledPostsCubit({
    required PostsRepository repository,
    this.pageSize = 20,
    Uuid? uuid,
    void Function(Object error, StackTrace stack)? onUnexpectedError,
  }) : _repository = repository,
       _uuid = uuid ?? const Uuid(),
       _onUnexpectedError = onUnexpectedError,
       super(const ScheduledPostsState());

  final PostsRepository _repository;
  final Uuid _uuid;
  final void Function(Object error, StackTrace stack)? _onUnexpectedError;
  final int pageSize;

  bool _refreshing = false;
  bool _loadingMore = false;

  /// The last failure of the banner was a next page (so Retry asks for it
  /// again) rather than a refresh.
  bool _noticeFromPaging = false;

  /// The first page, with the skeleton (also the error view's Retry).
  Future<void> load() async {
    emit(const ScheduledPostsState());
    await refresh();
  }

  /// Reloads the first page, keeping the rows on screen (pull to refresh).
  Future<void> refresh() async {
    if (_refreshing) return;
    _refreshing = true;
    try {
      final page = await _repository.listScheduledPosts(pageSize: pageSize);
      if (isClosed) return;
      _noticeFromPaging = false;
      emit(
        ScheduledPostsState(
          status: ScheduledPostsStatus.ready,
          items: _shown(page.scheduledPosts),
          nextPageToken: page.nextPageToken,
        ),
      );
    } on AppException catch (e) {
      if (isClosed) return;
      _noticeFromPaging = false;
      _failedLoad(e);
    } catch (error, stack) {
      _onUnexpectedError?.call(error, stack);
      if (isClosed) return;
      _noticeFromPaging = false;
      _failedLoad(const UnknownApiException('Something went wrong.'));
    } finally {
      _refreshing = false;
    }
  }

  void _failedLoad(AppException error) {
    if (state.items.isEmpty) {
      emit(
        ScheduledPostsState(status: ScheduledPostsStatus.error, error: error),
      );
    } else {
      emit(state.copyWith(notice: error));
    }
  }

  /// The next page, once the user is near the end. Guarded against concurrent
  /// calls; a failure keeps the rows and sets the banner.
  Future<void> loadMore() async {
    if (_loadingMore ||
        _refreshing ||
        !state.hasMore ||
        state.status != ScheduledPostsStatus.ready) {
      return;
    }
    _loadingMore = true;
    emit(
      state.copyWith(status: ScheduledPostsStatus.loadingMore, notice: null),
    );
    try {
      final page = await _repository.listScheduledPosts(
        pageToken: state.nextPageToken,
        pageSize: pageSize,
      );
      if (isClosed) return;
      final known = {for (final i in state.items) i.scheduledId};
      emit(
        state.copyWith(
          status: ScheduledPostsStatus.ready,
          items: [
            ...state.items,
            for (final i in _shown(page.scheduledPosts))
              if (!known.contains(i.scheduledId)) i,
          ],
          nextPageToken: page.nextPageToken,
        ),
      );
    } on AppException catch (e) {
      _pagingFailed(e);
    } catch (error, stack) {
      _onUnexpectedError?.call(error, stack);
      _pagingFailed(const UnknownApiException('Something went wrong.'));
    } finally {
      _loadingMore = false;
    }
  }

  void _pagingFailed(AppException error) {
    if (isClosed) return;
    _noticeFromPaging = true;
    emit(state.copyWith(status: ScheduledPostsStatus.ready, notice: error));
  }

  /// The banner's Retry: the failed page again, or a refresh.
  Future<void> retry() => _noticeFromPaging ? loadMore() : refresh();

  /// Cancels a PENDING [item], or dismisses a FAILED one. The row leaves at
  /// once; a failed call puts it back where it was.
  Future<ScheduledRemoval> remove(pb.ScheduledPost item) async {
    final index = state.items.indexWhere(
      (i) => i.scheduledId == item.scheduledId,
    );
    if (index < 0) {
      return const ScheduledRemoval(ScheduledRemovalOutcome.done);
    }
    emit(state.copyWith(items: [...state.items]..removeAt(index)));
    try {
      // The server only format-checks the key: a fresh one per tap.
      final current = await _repository.cancelScheduledPost(
        scheduledId: item.scheduledId,
        idempotencyKey: _uuid.v4(),
      );
      _refillIfEmptied();
      return ScheduledRemoval(
        current.status == ScheduledPostStatus.SCHEDULED_POST_STATUS_PUBLISHED
            ? ScheduledRemovalOutcome.tooLate
            : ScheduledRemovalOutcome.done,
      );
    } on NotFoundException {
      // Gone already (cleaned up after 7 days): nothing left to cancel.
      _refillIfEmptied();
      return const ScheduledRemoval(ScheduledRemovalOutcome.done);
    } on AppException catch (e) {
      _restore(item, index);
      return ScheduledRemoval(ScheduledRemovalOutcome.failed, e);
    } catch (error, stack) {
      _onUnexpectedError?.call(error, stack);
      _restore(item, index);
      return const ScheduledRemoval(
        ScheduledRemovalOutcome.failed,
        UnknownApiException('Something went wrong.'),
      );
    }
  }

  void _restore(pb.ScheduledPost item, int index) {
    if (isClosed) return;
    if (state.items.any((i) => i.scheduledId == item.scheduledId)) return;
    final items = [...state.items];
    items.insert(index.clamp(0, items.length), item);
    emit(state.copyWith(items: items));
  }

  /// Removing the last loaded row while more pages exist must not show the
  /// empty state: fetch the next page.
  void _refillIfEmptied() {
    if (isClosed) return;
    if (state.items.isEmpty && state.hasMore) unawaited(loadMore());
  }

  /// Only the items a user can act on, in the server order.
  List<pb.ScheduledPost> _shown(Iterable<pb.ScheduledPost> items) => [
    for (final i in items)
      if (i.status == ScheduledPostStatus.SCHEDULED_POST_STATUS_PENDING ||
          i.status == ScheduledPostStatus.SCHEDULED_POST_STATUS_FAILED)
        i,
  ];
}
