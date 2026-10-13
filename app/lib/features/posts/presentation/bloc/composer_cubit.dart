import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:uuid/uuid.dart';

import '../../../../core/network/app_exception.dart';
import '../../../../gen/dzeroth/common/v1/common.pb.dart' as common;
import '../../../../gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import '../../data/posts_repository.dart';
import '../../domain/post_text_rules.dart';
import 'pending_posts_cubit.dart';

enum ComposerStatus { editing, submitting, posted }

@immutable
class ComposerState {
  const ComposerState({
    required this.draft,
    this.status = ComposerStatus.editing,
    this.error,
    this.created,
  });

  final PostDraft draft;
  final ComposerStatus status;

  /// The server's view of the post, set with [ComposerStatus.posted] (the
  /// thread screen appends a new reply from it with no refetch).
  final pb.PostView? created;

  /// The last failed submit, shown once (snackbar / verify prompt) and
  /// cleared by the next edit or submit.
  final AppException? error;

  bool get isSubmitting => status == ComposerStatus.submitting;
  bool get canSubmit => draft.canPost && status == ComposerStatus.editing;

  ComposerState copyWith({
    PostDraft? draft,
    ComposerStatus? status,
    AppException? error,
    pb.PostView? created,
    bool clearError = false,
    bool clearCreated = false,
  }) => ComposerState(
    draft: draft ?? this.draft,
    status: status ?? this.status,
    error: clearError ? null : (error ?? this.error),
    created: clearCreated ? null : (created ?? this.created),
  );
}

/// Drives the compose screen (T16): live D9 counter, optimistic insert via
/// [PendingPostsCubit], rollback on error, and one idempotency key per
/// intent.
///
/// The key is generated at the first submit of a text and reused by every
/// retry of that same text (a dropped response can never create a second
/// post), even after the user edited to another text and back: keys are kept
/// per submitted text, so edit-and-revert cannot mint a second key for a post
/// that may already exist. A different text gets its own key (the server
/// would answer IDEMPOTENCY_KEY_REUSED for a different body), and a text's key
/// is dropped once its post succeeded.
/// [DegradedModeException] is never retried automatically; the user may tap
/// Post again.
/// How many failed texts keep their idempotency key (a handful of edits).
const _maxRememberedKeys = 8;

class ComposerCubit extends Cubit<ComposerState> {
  /// A top-level post: the optimistic item goes through [pending] with the
  /// viewer's [author] snapshot.
  ComposerCubit({
    required PostsRepository postsRepository,
    required PendingPostsCubit pending,
    required common.AuthorSnapshot author,
    Uuid? uuid,
    DateTime Function()? clock,
  }) : replyToPostId = '',
       _repository = postsRepository,
       _pending = pending,
       _author = author,
       _uuid = uuid ?? const Uuid(),
       _clock = clock ?? DateTime.now,
       super(ComposerState(draft: analyzePostDraft('')));

  /// A reply to [replyToPostId] (P3 thread screen). Replies never appear on
  /// Home, so there is no optimistic item here: the thread screen shows its
  /// own pending row while [ComposerState.isSubmitting].
  ComposerCubit.reply({
    required PostsRepository postsRepository,
    required this.replyToPostId,
    Uuid? uuid,
  }) : _repository = postsRepository,
       _pending = null,
       _author = null,
       _uuid = uuid ?? const Uuid(),
       _clock = DateTime.now,
       super(ComposerState(draft: analyzePostDraft('')));

  /// The post being replied to; empty for a top-level post.
  final String replyToPostId;

  final PostsRepository _repository;
  final PendingPostsCubit? _pending;
  final common.AuthorSnapshot? _author;
  final Uuid _uuid;
  final DateTime Function() _clock;

  /// Idempotency key per submitted text, insertion-ordered and bounded.
  final Map<String, String> _keys = {};
  String? _keyText;

  /// The key of the current intent, for tests and diagnostics.
  @visibleForTesting
  String? get currentKey => _keyText == null ? null : _keys[_keyText];

  void textChanged(String raw) {
    if (state.isSubmitting) return;
    emit(
      ComposerState(
        draft: analyzePostDraft(raw),
        status: ComposerStatus.editing,
      ),
    );
  }

  Future<void> submit() async {
    if (!state.canSubmit) return;
    final text = state.draft.text;
    final key = _keys.putIfAbsent(text, _uuid.v4);
    if (_keys.length > _maxRememberedKeys) _keys.remove(_keys.keys.first);
    _keyText = text;

    final pending = _pending;
    final author = _author;
    if (pending != null && author != null) {
      pending.add(
        PendingPost(
          localId: key,
          text: text,
          author: author,
          createdAt: _clock(),
        ),
      );
    }
    emit(
      state.copyWith(
        status: ComposerStatus.submitting,
        clearError: true,
        clearCreated: true,
      ),
    );
    try {
      final created = await _repository.createPost(
        idempotencyKey: key,
        text: text,
        replyToPostId: replyToPostId,
      );
      _keys.remove(text);
      _keyText = null;
      pending?.remove(key);
      if (!isClosed) {
        emit(state.copyWith(status: ComposerStatus.posted, created: created));
      }
    } on AppException catch (e) {
      _fail(key, e);
    } catch (_) {
      _fail(key, const UnknownApiException('Something went wrong.'));
    }
  }

  void _fail(String key, AppException error) {
    // Rollback: the optimistic item leaves Home/profile; the text stays in
    // the field and the key stays for the retry.
    _pending?.remove(key);
    if (isClosed) return;
    emit(state.copyWith(status: ComposerStatus.editing, error: error));
  }

  /// Marks the error as handled (shown), keeping the draft.
  void errorShown() {
    if (state.error != null) emit(state.copyWith(clearError: true));
  }
}
