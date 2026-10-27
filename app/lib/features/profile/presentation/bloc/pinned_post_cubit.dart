import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:uuid/uuid.dart';

import '../../../../core/network/app_exception.dart';
import '../../../posts/data/posts_repository.dart';
import 'pinned_post_state.dart';

/// Owns the Pinned row of one profile (W3-17, ADR-0024 D3): the single
/// `GetPost` of `Profile.pinned_post_id` and the rule for what a failure
/// means. A server that later embeds the pinned post in `GetProfile` replaces
/// only [pinChanged]'s fetch; no widget changes.
///
/// - [pinChanged] is told the profile's current pin id (initially, and after
///   the owner pins or unpins). `null`/`""` clears the row; the same id again
///   does nothing (one `GetPost` per pin per profile open); a new id fetches.
/// - NOT_FOUND hides the row silently ([PinnedPostStatus.hidden]): deleted,
///   taken down (the server does not unpin on a takedown, but `GetPost`
///   answers NOT_FOUND) or hidden by a block. Any other failure is
///   [PinnedPostStatus.failed], shown with Retry, and the post stays in the
///   feed below ([PinnedPostState.coveredPostId]).
/// - A post removed elsewhere (`PostsRepository.removedPosts`: deleted from
///   its detail screen, or a NOT_FOUND seen by another read) hides the row.
/// - Never polls; the row is not refreshed by pull-to-refresh (counts
///   reconcile on the next open).
class PinnedPostCubit extends Cubit<PinnedPostState> {
  PinnedPostCubit({required PostsRepository posts, this.onDeleted, Uuid? uuid})
    : _posts = posts,
      _uuid = uuid ?? const Uuid(),
      super(const PinnedPostState()) {
    _removedSub = _posts.removedPosts.listen(_onRemoved);
  }

  final PostsRepository _posts;
  final Uuid _uuid;

  /// Called after the pinned post was deleted through [deletePinned] and the
  /// server confirmed it (the profile drops its pin and post count).
  final void Function()? onDeleted;

  late final StreamSubscription<String> _removedSub;
  final Map<String, String> _deleteKeys = {};

  /// Bumped on every change of the pin, so a late answer for an earlier pin
  /// is dropped.
  int _generation = 0;

  /// The profile's pin is now [postId] (`null` or `""`: none).
  void pinChanged(String? postId) {
    final id = postId ?? '';
    if (id == state.postId && state.status != PinnedPostStatus.none) return;
    _generation++;
    if (id.isEmpty) {
      emit(const PinnedPostState());
      return;
    }
    unawaited(_fetch(id));
  }

  /// Retry after [PinnedPostStatus.failed].
  Future<void> retry() async {
    if (state.status != PinnedPostStatus.failed) return;
    _generation++;
    await _fetch(state.postId);
  }

  Future<void> _fetch(String id) async {
    final generation = _generation;
    emit(PinnedPostState(status: PinnedPostStatus.loading, postId: id));
    try {
      final view = await _posts.getPost(id);
      if (isClosed || generation != _generation) return;
      emit(
        PinnedPostState(status: PinnedPostStatus.ready, postId: id, view: view),
      );
    } on NotFoundException {
      if (isClosed || generation != _generation) return;
      emit(PinnedPostState(status: PinnedPostStatus.hidden, postId: id));
    } on AppException catch (e) {
      if (isClosed || generation != _generation) return;
      emit(
        PinnedPostState(status: PinnedPostStatus.failed, postId: id, error: e),
      );
    } catch (_) {
      if (isClosed || generation != _generation) return;
      emit(
        PinnedPostState(
          status: PinnedPostStatus.failed,
          postId: id,
          error: const UnknownApiException('Something went wrong.'),
        ),
      );
    }
  }

  void _onRemoved(String postId) {
    if (isClosed || postId != state.postId) return;
    if (state.status == PinnedPostStatus.hidden ||
        state.status == PinnedPostStatus.none) {
      return;
    }
    _generation++;
    emit(PinnedPostState(status: PinnedPostStatus.hidden, postId: postId));
  }

  /// Deletes the pinned post (its card's Delete, after the confirm). The row
  /// leaves at once and comes back if the call fails (the error is rethrown
  /// for the card's snackbar). One idempotency key per post until it
  /// succeeds, so a retry is the same intent.
  Future<void> deletePinned(String postId) async {
    final before = state;
    final key = _deleteKeys[postId] ??= _uuid.v4();
    _generation++;
    emit(
      PinnedPostState(
        status: PinnedPostStatus.hidden,
        postId: before.postId,
        view: before.view,
        deleting: true,
      ),
    );
    try {
      await _posts.deletePost(postId: postId, idempotencyKey: key);
    } catch (_) {
      if (!isClosed) emit(before);
      rethrow;
    }
    _deleteKeys.remove(postId);
    if (!isClosed) {
      emit(
        PinnedPostState(status: PinnedPostStatus.hidden, postId: before.postId),
      );
    }
    onDeleted?.call();
  }

  @override
  Future<void> close() async {
    await _removedSub.cancel();
    return super.close();
  }
}
