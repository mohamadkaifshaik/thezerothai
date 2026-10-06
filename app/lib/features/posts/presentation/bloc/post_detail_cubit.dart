import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:uuid/uuid.dart';

import '../../../../core/network/app_exception.dart';
import '../../../../gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import '../../data/posts_repository.dart';

enum PostDetailStatus { loading, ready, notFound, error, deleted }

@immutable
class PostDetailState {
  const PostDetailState({
    this.status = PostDetailStatus.loading,
    this.view,
    this.error,
  });

  final PostDetailStatus status;

  /// The post; set with [PostDetailStatus.ready].
  final pb.PostView? view;

  /// Set with [PostDetailStatus.error].
  final AppException? error;
}

/// Loads one post for `/post/:id` (T18). NOT_FOUND (missing, deleted, or
/// hidden by a block of the author, ADR-0010 D6) is a final state, not an
/// error: the repository already pruned the caches and nothing retries.
class PostDetailCubit extends Cubit<PostDetailState> {
  PostDetailCubit({
    required PostsRepository postsRepository,
    required String postId,
    Uuid? uuid,
  }) : _repository = postsRepository,
       _postId = postId,
       _uuid = uuid ?? const Uuid(),
       super(const PostDetailState());

  final PostsRepository _repository;
  final String _postId;
  final Uuid _uuid;
  String? _deleteKey;

  Future<void> load() async {
    emit(const PostDetailState());
    try {
      final view = await _repository.getPost(_postId);
      if (isClosed) return;
      emit(PostDetailState(status: PostDetailStatus.ready, view: view));
    } on NotFoundException {
      if (isClosed) return;
      emit(const PostDetailState(status: PostDetailStatus.notFound));
    } on ValidationException {
      // A malformed id in a typed or stale link: same as not found.
      if (isClosed) return;
      emit(const PostDetailState(status: PostDetailStatus.notFound));
    } on AppException catch (e) {
      if (isClosed) return;
      emit(PostDetailState(status: PostDetailStatus.error, error: e));
    }
  }

  /// Deletes this post. Success (even for an already-deleted post, ADR-0010
  /// D4) always means gone: the repository pruned every feed and the screen
  /// leaves. Failures are rethrown for the card's snackbar; the same key is
  /// reused by a retry.
  Future<void> deletePost() async {
    final key = _deleteKey ??= _uuid.v4();
    await _repository.deletePost(postId: _postId, idempotencyKey: key);
    _deleteKey = null;
    if (!isClosed) emit(const PostDetailState(status: PostDetailStatus.deleted));
  }
}
