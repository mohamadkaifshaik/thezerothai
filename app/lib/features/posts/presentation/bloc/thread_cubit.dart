import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:uuid/uuid.dart';

import '../../../../core/network/app_exception.dart';
import '../../../../gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import '../../data/posts_repository.dart';

enum ThreadStatus {
  loading,
  ready,

  /// The focal post is missing, deleted or hidden (one answer for all).
  notFound,

  /// FEATURE_REPLIES is off for this caller: the screen falls back to the
  /// plain post view (`GetPost`).
  disabled,
  error,

  /// The focal post was deleted by the viewer; the screen leaves.
  deleted,
}

@immutable
class ThreadState {
  const ThreadState({
    this.status = ThreadStatus.loading,
    this.focal,
    this.parent,
    this.root,
    this.parentUnavailable = false,
    this.rootUnavailable = false,
    this.replies = const [],
    this.nextPageToken = '',
    this.loadingMore = false,
    this.loadMoreError,
    this.error,
    this.hiddenAuthors = const {},
    this.repliesDisabled = false,
  });

  final ThreadStatus status;
  final pb.PostView? focal;

  /// Context above the focal post; null when the focal post is a root or the
  /// context is unavailable (see the flags: render a tombstone).
  final pb.PostView? parent;
  final pb.PostView? root;
  final bool parentUnavailable;
  final bool rootUnavailable;

  /// Conversation posts, chronological, excluding focal/parent/root.
  final List<pb.PostView> replies;
  final String nextPageToken;
  final bool loadingMore;

  /// The last failed "more replies" page (inline retry); the loaded replies
  /// stay visible.
  final AppException? loadMoreError;

  /// Set with [ThreadStatus.error].
  final AppException? error;

  /// Authors the viewer blocked or muted from a reply's menu: hidden at once.
  final Set<String> hiddenAuthors;

  /// A reply attempt was answered FEATURE_DISABLED: the composer goes away
  /// but the conversation stays readable.
  final bool repliesDisabled;

  bool get hasMore => nextPageToken.isNotEmpty;

  /// Replies to render (hidden authors removed).
  List<pb.PostView> get visibleReplies => hiddenAuthors.isEmpty
      ? replies
      : [
          for (final r in replies)
            if (!hiddenAuthors.contains(r.post.author.userId)) r,
        ];

  ThreadState copyWith({
    ThreadStatus? status,
    List<pb.PostView>? replies,
    String? nextPageToken,
    bool? loadingMore,
    AppException? loadMoreError,
    bool clearLoadMoreError = false,
    Set<String>? hiddenAuthors,
    bool? repliesDisabled,
  }) => ThreadState(
    status: status ?? this.status,
    focal: focal,
    parent: parent,
    root: root,
    parentUnavailable: parentUnavailable,
    rootUnavailable: rootUnavailable,
    replies: replies ?? this.replies,
    nextPageToken: nextPageToken ?? this.nextPageToken,
    loadingMore: loadingMore ?? this.loadingMore,
    loadMoreError: clearLoadMoreError
        ? null
        : (loadMoreError ?? this.loadMoreError),
    error: error,
    hiddenAuthors: hiddenAuthors ?? this.hiddenAuthors,
    repliesDisabled: repliesDisabled ?? this.repliesDisabled,
  );
}

/// Loads one conversation for `/post/:id` when FEATURE_REPLIES is on: the
/// focal post, parent/root context with tombstones, and replies paged by the
/// server's opaque token (default page 10; no polling, pull-to-refresh only).
///
/// - NOT_FOUND on the focal post is a final state; FEATURE_DISABLED (the
///   flag turned off under us) is [ThreadStatus.disabled] so the screen can
///   degrade to the plain post view instead of an error.
/// - A page may come back short or empty while a token is still present
///   (blocked/muted authors are dropped server-side): "more" keeps following
///   the token. A rejected token restarts the thread once.
class ThreadCubit extends Cubit<ThreadState> {
  ThreadCubit({
    required PostsRepository postsRepository,
    required String postId,
    Uuid? uuid,
  }) : _repository = postsRepository,
       _postId = postId,
       _uuid = uuid ?? const Uuid(),
       super(const ThreadState());

  final PostsRepository _repository;
  final String _postId;
  final Uuid _uuid;
  final Map<String, String> _deleteKeys = {};

  /// First page. Shows the loading state (use [refresh] to keep content).
  Future<void> load() async {
    emit(const ThreadState());
    await _fetchFirst(keepOnError: false);
  }

  /// Pull-to-refresh: replaces the thread in place; a failure keeps the old
  /// content on screen.
  Future<void> refresh() async {
    if (state.status != ThreadStatus.ready) return load();
    await _fetchFirst(keepOnError: true);
  }

  Future<void> _fetchFirst({required bool keepOnError}) async {
    try {
      final response = await _repository.getThread(_postId);
      if (isClosed) return;
      emit(_fromResponse(response));
    } on NotFoundException {
      if (isClosed) return;
      emit(const ThreadState(status: ThreadStatus.notFound));
    } on ValidationException {
      // A malformed id in a typed or stale link: same as not found.
      if (isClosed) return;
      emit(const ThreadState(status: ThreadStatus.notFound));
    } on FeatureDisabledException {
      if (isClosed) return;
      emit(const ThreadState(status: ThreadStatus.disabled));
    } on AppException catch (e) {
      if (isClosed || keepOnError) return;
      emit(ThreadState(status: ThreadStatus.error, error: e));
    }
  }

  ThreadState _fromResponse(pb.GetThreadResponse r) {
    final hasFocal = r.hasFocal();
    if (!hasFocal) return const ThreadState(status: ThreadStatus.notFound);
    final focalPost = r.focal.post;
    return ThreadState(
      status: ThreadStatus.ready,
      focal: r.focal,
      parent: r.hasParent() ? r.parent : null,
      root: r.hasRoot() ? r.root : null,
      parentUnavailable: r.parentUnavailable,
      rootUnavailable: r.rootUnavailable,
      replies: [
        for (final p in r.replies)
          if (p.post.postId != focalPost.postId) p,
      ],
      nextPageToken: r.nextPageToken,
    );
  }

  /// Next page of replies; guarded against concurrent loads.
  Future<void> loadMore() async {
    final s = state;
    if (s.status != ThreadStatus.ready || s.loadingMore || !s.hasMore) return;
    emit(s.copyWith(loadingMore: true, clearLoadMoreError: true));
    try {
      final response = await _repository.getThread(
        _postId,
        pageToken: s.nextPageToken,
      );
      if (isClosed) return;
      final seen = {for (final r in state.replies) r.post.postId};
      emit(
        state.copyWith(
          replies: [
            ...state.replies,
            for (final p in response.replies)
              if (seen.add(p.post.postId) &&
                  p.post.postId != s.focal?.post.postId)
                p,
          ],
          nextPageToken: response.nextPageToken,
          loadingMore: false,
        ),
      );
    } on ValidationException {
      // Token expired or rejected: one cold restart, not a dead end.
      if (isClosed) return;
      await load();
    } on NotFoundException {
      if (isClosed) return;
      emit(const ThreadState(status: ThreadStatus.notFound));
    } on FeatureDisabledException {
      if (isClosed) return;
      emit(const ThreadState(status: ThreadStatus.disabled));
    } on AppException catch (e) {
      if (isClosed) return;
      emit(state.copyWith(loadingMore: false, loadMoreError: e));
    }
  }

  /// The viewer's own reply was created: show it at the end at once (a later
  /// page that carries it again is deduplicated).
  void replyPosted(pb.PostView reply) {
    if (state.status != ThreadStatus.ready) return;
    if (state.replies.any((r) => r.post.postId == reply.post.postId)) return;
    emit(state.copyWith(replies: [...state.replies, reply]));
  }

  /// Replying turned out to be disabled: hide the composer only.
  void repliesBecameUnavailable() {
    if (!state.repliesDisabled) emit(state.copyWith(repliesDisabled: true));
  }

  /// Hides (blocked/muted) or restores an author's replies at once.
  void setAuthorHidden(String userId, {required bool hidden}) {
    if (userId.isEmpty) return;
    final next = {...state.hiddenAuthors};
    final changed = hidden ? next.add(userId) : next.remove(userId);
    if (changed) emit(state.copyWith(hiddenAuthors: next));
  }

  /// Deletes the focal post (leaves the screen) or one of the loaded posts
  /// (removed in place). Failures are rethrown for the card's snackbar; a
  /// retry reuses the same idempotency key.
  Future<void> deletePost(String postId) async {
    final key = _deleteKeys.putIfAbsent(postId, _uuid.v4);
    await _repository.deletePost(postId: postId, idempotencyKey: key);
    _deleteKeys.remove(postId);
    if (isClosed) return;
    if (postId == _postId) {
      emit(const ThreadState(status: ThreadStatus.deleted));
      return;
    }
    emit(
      state.copyWith(
        replies: [
          for (final r in state.replies)
            if (r.post.postId != postId) r,
        ],
      ),
    );
  }
}
