import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/network/app_exception.dart';
import '../../../../gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import '../../../posts/data/posts_repository.dart';
import '../../data/post_history_repository.dart';
import '../../domain/bookmark_history_feature_flag.dart';

enum PostHistoryStatus { loading, ready, error }

/// The History tab: [items] are the opened posts still readable, newest first.
@immutable
class PostHistoryState {
  const PostHistoryState({
    this.status = PostHistoryStatus.loading,
    this.items = const [],
    this.error,
  });

  final PostHistoryStatus status;
  final List<pb.PostView> items;

  /// Set with [PostHistoryStatus.error] (the device list could not be read,
  /// or a post read failed for a reason other than "gone").
  final AppException? error;
}

/// Turns the device's history ids into live post cards.
///
/// - Reads each id once through `PostsRepository.getPost` (no batch RPC
///   exists), [kBookmarkHistoryReadConcurrency] at a time, and keeps the
///   stored order.
/// - A post that no longer loads, or that comes back withheld (a protected
///   author the viewer cannot see now), drops out of the list and out of the
///   stored history. A removed post is pruned by the repository already.
/// - Any other failure fails the load (the tab shows its error with Retry).
/// - [clear] removes this account's history.
class PostHistoryCubit extends Cubit<PostHistoryState> {
  PostHistoryCubit({
    required PostHistoryRepository history,
    required PostsRepository posts,
    required String uid,
  }) : _history = history,
       _posts = posts,
       _uid = uid,
       super(const PostHistoryState());

  final PostHistoryRepository _history;
  final PostsRepository _posts;
  final String _uid;

  Future<void> load() async {
    emit(const PostHistoryState());
    try {
      final ids = await _history.recentPostIds(_uid);
      final views = <pb.PostView>[];
      for (
        var start = 0;
        start < ids.length;
        start += kBookmarkHistoryReadConcurrency
      ) {
        final chunk = ids.sublist(
          start,
          (start + kBookmarkHistoryReadConcurrency).clamp(0, ids.length),
        );
        final results = await Future.wait(chunk.map(_readOne));
        for (final view in results) {
          if (view != null) views.add(view);
        }
      }
      if (isClosed) return;
      emit(PostHistoryState(status: PostHistoryStatus.ready, items: views));
    } on AppException catch (e) {
      if (isClosed) return;
      emit(PostHistoryState(status: PostHistoryStatus.error, error: e));
    }
  }

  Future<void> clear() async {
    await _history.clear(_uid);
    if (isClosed) return;
    emit(const PostHistoryState(status: PostHistoryStatus.ready));
  }

  /// One post, or null when it is gone or withheld (then it is also removed
  /// from the stored history).
  Future<pb.PostView?> _readOne(String postId) async {
    try {
      final view = await _posts.getPost(postId);
      if (view.withheld) {
        await _history.remove(uid: _uid, postId: postId);
        return null;
      }
      return view;
    } on NotFoundException {
      await _history.remove(uid: _uid, postId: postId);
      return null;
    } on ValidationException {
      await _history.remove(uid: _uid, postId: postId);
      return null;
    }
  }
}
