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

  /// Post now only: the item had been cancelled (or cleaned up) meanwhile,
  /// so nothing was posted. The row is gone.
  noLongerScheduled,
}

/// How an Edit ended.
enum ScheduledEditOutcome {
  /// Saved: the row shows the new text and time.
  saved,

  /// The post went out before the edit landed (not an error); the row is
  /// gone.
  tooLate,

  /// The item had been cancelled or cleaned up meanwhile; the row is gone.
  noLongerScheduled,

  /// The call failed; nothing changed.
  failed,
}

/// The result of [ScheduledPostsCubit.edit].
class ScheduledEdit {
  const ScheduledEdit(this.outcome, [this.error]);

  final ScheduledEditOutcome outcome;

  /// Set with [ScheduledEditOutcome.failed].
  final AppException? error;
}

/// The result of [ScheduledPostsCubit.remove].
class ScheduledRemoval {
  const ScheduledRemoval(this.outcome, [this.error]);

  final ScheduledRemovalOutcome outcome;

  /// Set with [ScheduledRemovalOutcome.failed].
  final AppException? error;
}

/// Pages the caller's scheduled posts and removes rows:
/// Cancel for a PENDING item, Dismiss for a FAILED one (the same RPC).
///
/// - Only PENDING and FAILED items are shown, in the server order (oldest
///   publish time first).
/// - A failed refresh or next page keeps the rows already loaded and raises
///   [ScheduledPostsState.notice]; only a failed first page is an error view.
/// - A failed next page stops automatic paging (each try costs 1 + page
///   reads, and a degraded answer must never be retried on its own): only
///   [retry] or a successful [refresh] lets [loadMore] send again.
/// - FEATURE_DISABLED (scheduling switched off for everyone) replaces the
///   list with the error status carrying that exception, which the screen
///   words as "not available" with no Retry; a pull to refresh tries again.
/// - [remove] is optimistic: the row leaves at once and comes back if the
///   call fails. An item that turned PUBLISHED or CANCELLED meanwhile (or no
///   longer exists) counts as done. While a removal runs its row stays out of
///   every refresh and page that lands meanwhile, and a second [remove] of the
///   same row shares the first call's answer.
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

  /// A next page failed: [loadMore] sends nothing until [retry] or a
  /// successful [refresh] (the scroll listener calls it on every tick).
  bool _pagingHalted = false;

  /// Removals in flight by id: their rows are filtered out of whatever a
  /// refresh or page returns meanwhile (the server may not have applied the
  /// cancel yet), and a second tap shares the running call.
  final Map<String, Future<ScheduledRemoval>> _removing = {};

  /// The last failure of the banner was a next page (so Retry asks for it
  /// again) rather than a refresh.
  bool _noticeFromPaging = false;

  /// [ScheduledPostsState.notice] is about a failed next page: the screen
  /// shows it at the end of the list, where the user is, instead of at the top.
  bool get noticeFromPaging => _noticeFromPaging;

  /// The first page, with the skeleton (also the error view's Retry).
  Future<void> load() async {
    _pagingHalted = false;
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
      _pagingHalted = false;
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
    if (error is FeatureDisabledException) return _unavailable(error);
    if (state.items.isEmpty) {
      emit(
        ScheduledPostsState(status: ScheduledPostsStatus.error, error: error),
      );
    } else {
      emit(state.copyWith(notice: error));
    }
  }

  /// Scheduling is off for everyone: nothing to list or cancel. The screen
  /// shows its own "not available" state for this error (no Retry).
  void _unavailable(FeatureDisabledException error) {
    if (isClosed) return;
    _noticeFromPaging = false;
    emit(ScheduledPostsState(status: ScheduledPostsStatus.error, error: error));
  }

  /// The next page, once the user is near the end. Guarded against concurrent
  /// calls; a failure keeps the rows, sets the banner and halts automatic
  /// paging until [retry] (or a successful [refresh]).
  Future<void> loadMore() async {
    if (_loadingMore ||
        _refreshing ||
        _pagingHalted ||
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
    if (error is FeatureDisabledException) return _unavailable(error);
    _pagingHalted = true;
    _noticeFromPaging = true;
    emit(state.copyWith(status: ScheduledPostsStatus.ready, notice: error));
  }

  /// The banner's Retry: the failed page again, or a refresh. The only way
  /// (besides a successful refresh) to resume paging after a failed page.
  Future<void> retry() {
    if (!_noticeFromPaging) return refresh();
    _pagingHalted = false;
    return loadMore();
  }

  /// Cancels a PENDING [item], or dismisses a FAILED one. The row leaves at
  /// once; a failed call puts it back where it was.
  Future<ScheduledRemoval> remove(pb.ScheduledPost item) =>
      _take(item, postNow: false);

  /// Publishes a PENDING [item] now (`PublishScheduledPostNow`). Like
  /// [remove], the row leaves at once and a failed call puts it back; a
  /// row being removed or posted shares the running call's answer.
  Future<ScheduledRemoval> postNow(pb.ScheduledPost item) =>
      _take(item, postNow: true);

  Future<ScheduledRemoval> _take(
    pb.ScheduledPost item, {
    required bool postNow,
  }) {
    final id = item.scheduledId;
    // A second tap while the first call runs gets that call's answer: never
    // "cancelled" or "posted" before the server said so.
    final running = _removing[id];
    if (running != null) return running;
    final index = state.items.indexWhere((i) => i.scheduledId == id);
    if (index < 0) {
      return Future.value(const ScheduledRemoval(ScheduledRemovalOutcome.done));
    }
    // The optimistic removal happens in the synchronous part of the call.
    final call = _send(item, index, postNow: postNow).whenComplete(() {
      // A block body: returning the removed future would make it wait on
      // itself.
      _removing.remove(id);
    });
    _removing[id] = call;
    return call;
  }

  Future<ScheduledRemoval> _send(
    pb.ScheduledPost item,
    int index, {
    required bool postNow,
  }) async {
    emit(state.copyWith(items: [...state.items]..removeAt(index)));
    try {
      // The server only format-checks the key: a fresh one per tap.
      final current = postNow
          ? await _repository.publishScheduledPostNow(
              scheduledId: item.scheduledId,
              idempotencyKey: _uuid.v4(),
            )
          : await _repository.cancelScheduledPost(
              scheduledId: item.scheduledId,
              idempotencyKey: _uuid.v4(),
            );
      _refillIfEmptied();
      final published =
          current.status == ScheduledPostStatus.SCHEDULED_POST_STATUS_PUBLISHED;
      return ScheduledRemoval(
        postNow
            ? (published
                  ? ScheduledRemovalOutcome.done
                  : ScheduledRemovalOutcome.noLongerScheduled)
            : (published
                  ? ScheduledRemovalOutcome.tooLate
                  : ScheduledRemovalOutcome.done),
      );
    } on NotFoundException {
      // Gone already (cleaned up after 7 days): nothing left to cancel, and
      // nothing to post.
      _refillIfEmptied();
      return ScheduledRemoval(
        postNow
            ? ScheduledRemovalOutcome.noLongerScheduled
            : ScheduledRemovalOutcome.done,
      );
    } on FeatureDisabledException catch (e) {
      // Scheduling was switched off for everyone: the list is not usable.
      _unavailable(e);
      return ScheduledRemoval(ScheduledRemovalOutcome.failed, e);
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

  /// Edits a PENDING [item]: [text] and [publishAt] are sent only when
  /// given (unchanged fields stay out of the request). Not optimistic: the
  /// row changes when the server answers, then takes its place in the
  /// loaded rows by its new time.
  Future<ScheduledEdit> edit(
    pb.ScheduledPost item, {
    String? text,
    DateTime? publishAt,
  }) async {
    final id = item.scheduledId;
    try {
      final updated = await _repository.updateScheduledPost(
        scheduledId: id,
        idempotencyKey: _uuid.v4(),
        text: text,
        publishAt: publishAt,
      );
      if (isClosed) return const ScheduledEdit(ScheduledEditOutcome.saved);
      final rest = [
        for (final i in state.items)
          if (i.scheduledId != id) i,
      ];
      switch (updated.status) {
        case ScheduledPostStatus.SCHEDULED_POST_STATUS_PENDING:
          final items = [...rest, updated]
            ..sort(
              (a, b) =>
                  a.publishAt.toDateTime().compareTo(b.publishAt.toDateTime()),
            );
          emit(state.copyWith(items: items));
          return const ScheduledEdit(ScheduledEditOutcome.saved);
        case ScheduledPostStatus.SCHEDULED_POST_STATUS_PUBLISHED:
          emit(state.copyWith(items: rest));
          _refillIfEmptied();
          return const ScheduledEdit(ScheduledEditOutcome.tooLate);
        default:
          emit(state.copyWith(items: rest));
          _refillIfEmptied();
          return const ScheduledEdit(ScheduledEditOutcome.noLongerScheduled);
      }
    } on NotFoundException {
      if (!isClosed) {
        emit(
          state.copyWith(
            items: [
              for (final i in state.items)
                if (i.scheduledId != id) i,
            ],
          ),
        );
        _refillIfEmptied();
      }
      return const ScheduledEdit(ScheduledEditOutcome.noLongerScheduled);
    } on FeatureDisabledException catch (e) {
      _unavailable(e);
      return ScheduledEdit(ScheduledEditOutcome.failed, e);
    } on AppException catch (e) {
      return ScheduledEdit(ScheduledEditOutcome.failed, e);
    } catch (error, stack) {
      _onUnexpectedError?.call(error, stack);
      return const ScheduledEdit(
        ScheduledEditOutcome.failed,
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

  /// Only the items a user can act on, in the server order, minus the ones
  /// being removed right now.
  List<pb.ScheduledPost> _shown(Iterable<pb.ScheduledPost> items) => [
    for (final i in items)
      if ((i.status == ScheduledPostStatus.SCHEDULED_POST_STATUS_PENDING ||
              i.status == ScheduledPostStatus.SCHEDULED_POST_STATUS_FAILED) &&
          !_removing.containsKey(i.scheduledId))
        i,
  ];
}
