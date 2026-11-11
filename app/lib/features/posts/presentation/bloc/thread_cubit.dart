import 'dart:async';

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
    this.refreshError,
    this.hiddenAuthors = const {},
    this.hiddenReplies = const {},
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

  /// The last failed pull-to-refresh over visible content (a one-shot
  /// snackbar; [ThreadCubit.refreshErrorShown] clears it).
  final AppException? refreshError;

  /// Authors the viewer blocked or muted from a reply's menu: hidden at once.
  final Set<String> hiddenAuthors;

  /// Replies a community moderator removed from this thread: gone at
  /// once, back if the call fails. The server drops them on the next read.
  final Set<String> hiddenReplies;

  /// A reply attempt was answered FEATURE_DISABLED: the composer goes away
  /// but the conversation stays readable.
  final bool repliesDisabled;

  bool get hasMore => nextPageToken.isNotEmpty;

  /// How many posts the loaded part of the conversation holds when it is a
  /// self-thread: the open post and its loaded context, all by one author,
  /// plus the same author's replies that continue it (each answering the one
  /// before). 0 when it is not one (a context post by someone else or
  /// unavailable, or fewer than two posts). Drives the "Thread · N posts"
  /// line of the header.
  int get selfThreadLength {
    final f = focal;
    if (f == null) return 0;
    final author = f.post.author.userId;
    if (author.isEmpty) return 0;
    if (parentUnavailable || rootUnavailable) return 0;
    // Context counts only when the links are proven: the parent answers the
    // root (or is it) and the open post answers the parent. A missing middle
    // post leaves the length unknown, so no count.
    final ids = <String>{f.post.postId};
    final p = parent;
    final r = root;
    if (f.post.replyToPostId.isNotEmpty) {
      final ancestor =
          p ?? (r != null && r.post.postId == f.post.replyToPostId ? r : null);
      if (ancestor == null || ancestor.post.postId != f.post.replyToPostId) {
        return 0;
      }
      if (ancestor.post.author.userId != author) return 0;
      ids.add(ancestor.post.postId);
      if (r != null && r.post.postId != ancestor.post.postId) {
        if (ancestor.post.replyToPostId != r.post.postId) return 0;
        if (r.post.author.userId != author) return 0;
        ids.add(r.post.postId);
      }
    }
    var tail = f.post.postId;
    final byParent = <String, pb.PostView>{};
    for (final reply in visibleReplies) {
      if (reply.post.author.userId == author) {
        byParent.putIfAbsent(reply.post.replyToPostId, () => reply);
      }
    }
    for (var next = byParent[tail]; next != null; next = byParent[tail]) {
      if (!ids.add(next.post.postId)) break;
      tail = next.post.postId;
    }
    return ids.length >= 2 ? ids.length : 0;
  }

  /// Replies to render (hidden authors removed).
  List<pb.PostView> get visibleReplies =>
      hiddenAuthors.isEmpty && hiddenReplies.isEmpty
      ? replies
      : [
          for (final r in replies)
            if (!hiddenAuthors.contains(r.post.author.userId) &&
                !hiddenReplies.contains(r.post.postId))
              r,
        ];

  /// The community the conversation belongs to: the root post's label (the
  /// focal post itself when it is the root). Null when there is none or the
  /// root is unavailable (a hidden root has no label).
  pb.CommunityRef? get rootCommunity {
    final f = focal;
    if (f == null) return null;
    final pb.PostView? rootView;
    if (f.post.replyToPostId.isEmpty) {
      rootView = f;
    } else {
      rootView =
          root ??
          (f.post.replyToPostId == f.post.conversationId ? parent : null);
    }
    return rootView != null && rootView.post.hasCommunity()
        ? rootView.post.community
        : null;
  }

  ThreadState copyWith({
    ThreadStatus? status,
    List<pb.PostView>? replies,
    String? nextPageToken,
    bool? loadingMore,
    AppException? loadMoreError,
    bool clearLoadMoreError = false,
    AppException? refreshError,
    bool clearRefreshError = false,
    Set<String>? hiddenAuthors,
    Set<String>? hiddenReplies,
    bool? repliesDisabled,
    bool dropParent = false,
    bool dropRoot = false,
  }) => ThreadState(
    status: status ?? this.status,
    focal: focal,
    // A removed context post becomes a tombstone.
    parent: dropParent ? null : parent,
    root: dropRoot ? null : root,
    parentUnavailable: parentUnavailable || dropParent,
    rootUnavailable: rootUnavailable || dropRoot,
    replies: replies ?? this.replies,
    nextPageToken: nextPageToken ?? this.nextPageToken,
    loadingMore: loadingMore ?? this.loadingMore,
    loadMoreError: clearLoadMoreError
        ? null
        : (loadMoreError ?? this.loadMoreError),
    error: error,
    refreshError: clearRefreshError
        ? null
        : (refreshError ?? this.refreshError),
    hiddenAuthors: hiddenAuthors ?? this.hiddenAuthors,
    hiddenReplies: hiddenReplies ?? this.hiddenReplies,
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
///   the token. A rejected token restarts the thread once (until a page
///   succeeds again).
/// - A failed page stops automatic paging: only [retryLoadMore] (the inline
///   Retry) tries again. While a RATE_LIMITED hold runs, the repository
///   answers with it without sending (`RateLimitHold`).
/// - Posts that leave every cached feed ([PostsRepository.removedPosts]) are
///   dropped from the replies; a removed parent/root becomes a tombstone.
class ThreadCubit extends Cubit<ThreadState> {
  ThreadCubit({
    required PostsRepository postsRepository,
    required String postId,
    Uuid? uuid,
  }) : _repository = postsRepository,
       _postId = postId,
       _uuid = uuid ?? const Uuid(),
       super(const ThreadState()) {
    _removedSub = _repository.removedPosts.listen(_onRemoved);
  }

  final PostsRepository _repository;
  final String _postId;
  final Uuid _uuid;
  final Map<String, String> _deleteKeys = {};
  late final StreamSubscription<String> _removedSub;

  /// The viewer's own replies appended locally ([replyPosted]) and not yet
  /// seen in a fetched page: the server's position wins when one arrives.
  final Set<String> _localReplies = {};

  /// Bumped whenever the whole thread is replaced; a page request that
  /// started before it must not write its (stale) token or replies.
  int _generation = 0;

  /// True once a rejected page token restarted the thread; cleared by the
  /// next successful page.
  bool _restarted = false;

  /// First page. Shows the loading state (use [refresh] to keep content).
  Future<void> load() async {
    _generation++;
    // The viewer's local choices survive a reload.
    emit(
      ThreadState(
        hiddenAuthors: state.hiddenAuthors,
        hiddenReplies: state.hiddenReplies,
        repliesDisabled: state.repliesDisabled,
      ),
    );
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
      _generation++;
      _localReplies.clear();
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
      if (isClosed) return;
      if (keepOnError) {
        // The old thread stays; the screen says why nothing changed.
        emit(state.copyWith(refreshError: e));
        return;
      }
      emit(ThreadState(status: ThreadStatus.error, error: e));
    }
  }

  /// Marks a failed refresh as shown.
  void refreshErrorShown() {
    if (state.refreshError != null) {
      emit(state.copyWith(clearRefreshError: true));
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
      hiddenAuthors: state.hiddenAuthors,
      hiddenReplies: state.hiddenReplies,
      repliesDisabled: state.repliesDisabled,
    );
  }

  /// Next page of replies (scroll near the end / "Show more replies").
  /// No-op while loading, when exhausted, and after a failed page until
  /// [retryLoadMore]: scrolling must not retry a failing request.
  Future<void> loadMore() async {
    if (state.loadMoreError != null) return;
    await _loadPage();
  }

  /// The user tapped Retry under a failed page.
  Future<void> retryLoadMore() async {
    if (state.loadMoreError == null) return;
    _restarted = false;
    await _loadPage();
  }

  Future<void> _loadPage() async {
    final s = state;
    if (isClosed ||
        s.status != ThreadStatus.ready ||
        s.loadingMore ||
        !s.hasMore) {
      return;
    }
    final generation = _generation;
    emit(s.copyWith(loadingMore: true, clearLoadMoreError: true));
    try {
      final response = await _repository.getThread(
        _postId,
        pageToken: s.nextPageToken,
      );
      if (isClosed || generation != _generation) return;
      // A reply the viewer added locally that the server now sends keeps
      // the server's position (replies are chronological).
      final pageIds = {for (final p in response.replies) p.post.postId};
      final local = _localReplies.intersection(pageIds);
      _localReplies.removeAll(local);
      final base = [
        for (final r in state.replies)
          if (!local.contains(r.post.postId)) r,
      ];
      final seen = {for (final r in base) r.post.postId};
      _restarted = false;
      emit(
        state.copyWith(
          replies: [
            ...base,
            for (final p in response.replies)
              if (seen.add(p.post.postId) &&
                  p.post.postId != s.focal?.post.postId)
                p,
          ],
          nextPageToken: response.nextPageToken,
          loadingMore: false,
        ),
      );
    } on ValidationException catch (e) {
      if (isClosed || generation != _generation) return;
      if (_restarted) {
        // The restart's own token was rejected too: stop, offer Retry.
        emit(state.copyWith(loadingMore: false, loadMoreError: e));
        return;
      }
      // Token expired or rejected: one cold restart, not a dead end.
      _restarted = true;
      await load();
    } on NotFoundException {
      if (isClosed || generation != _generation) return;
      emit(const ThreadState(status: ThreadStatus.notFound));
    } on FeatureDisabledException {
      if (isClosed || generation != _generation) return;
      emit(const ThreadState(status: ThreadStatus.disabled));
    } on AppException catch (e) {
      if (isClosed || generation != _generation) return;
      emit(state.copyWith(loadingMore: false, loadMoreError: e));
    }
  }

  void _onRemoved(String postId) {
    final s = state;
    if (isClosed || s.status != ThreadStatus.ready || postId == _postId) {
      return;
    }
    final inReplies = s.replies.any((r) => r.post.postId == postId);
    final parentGone = s.parent?.post.postId == postId;
    final rootGone = s.root?.post.postId == postId;
    if (!inReplies && !parentGone && !rootGone) return;
    emit(
      s.copyWith(
        replies: inReplies
            ? [
                for (final r in s.replies)
                  if (r.post.postId != postId) r,
              ]
            : null,
        dropParent: parentGone,
        dropRoot: rootGone,
      ),
    );
  }

  @override
  Future<void> close() async {
    await _removedSub.cancel();
    return super.close();
  }

  /// The viewer's own reply was created: show it at the end at once (a later
  /// page that carries it again is deduplicated).
  void replyPosted(pb.PostView reply) {
    if (state.status != ThreadStatus.ready) return;
    if (state.replies.any((r) => r.post.postId == reply.post.postId)) return;
    _localReplies.add(reply.post.postId);
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

  /// A moderator removed [replyId] from the community view: it leaves the
  /// open thread at once. [showReplyAgain] rolls it back.
  void hideReplyLocally(String replyId) {
    if (isClosed || state.hiddenReplies.contains(replyId)) return;
    emit(state.copyWith(hiddenReplies: {...state.hiddenReplies, replyId}));
  }

  void showReplyAgain(String replyId) {
    if (isClosed || !state.hiddenReplies.contains(replyId)) return;
    emit(
      state.copyWith(hiddenReplies: {...state.hiddenReplies}..remove(replyId)),
    );
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
