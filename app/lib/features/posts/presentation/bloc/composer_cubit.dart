import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:uuid/uuid.dart';

import '../../../../core/network/app_exception.dart';
import '../../../../gen/dzeroth/common/v1/common.pb.dart' as common;
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
  });

  final PostDraft draft;
  final ComposerStatus status;

  /// The last failed submit, shown once (snackbar / verify prompt) and
  /// cleared by the next edit or submit.
  final AppException? error;

  bool get isSubmitting => status == ComposerStatus.submitting;
  bool get canSubmit => draft.canPost && status == ComposerStatus.editing;

  ComposerState copyWith({
    PostDraft? draft,
    ComposerStatus? status,
    AppException? error,
    bool clearError = false,
  }) => ComposerState(
    draft: draft ?? this.draft,
    status: status ?? this.status,
    error: clearError ? null : (error ?? this.error),
  );
}

/// Drives the compose screen (T16): live D9 counter, optimistic insert via
/// [PendingPostsCubit], rollback on error, and one idempotency key per
/// intent.
///
/// The key is generated at the first submit and reused by every retry of the
/// same text (a dropped response can never create a second post). It is
/// dropped when the text changes (the server would answer
/// IDEMPOTENCY_KEY_REUSED for a different body) and once the post succeeded.
/// [DegradedModeException] is never retried automatically; the user may tap
/// Post again.
class ComposerCubit extends Cubit<ComposerState> {
  ComposerCubit({
    required PostsRepository postsRepository,
    required PendingPostsCubit pending,
    required common.AuthorSnapshot author,
    Uuid? uuid,
    DateTime Function()? clock,
  }) : _repository = postsRepository,
       _pending = pending,
       _author = author,
       _uuid = uuid ?? const Uuid(),
       _clock = clock ?? DateTime.now,
       super(ComposerState(draft: analyzePostDraft('')));

  final PostsRepository _repository;
  final PendingPostsCubit _pending;
  final common.AuthorSnapshot _author;
  final Uuid _uuid;
  final DateTime Function() _clock;

  String? _key;
  String? _keyText;

  /// The key of the current intent, for tests and diagnostics.
  @visibleForTesting
  String? get currentKey => _key;

  void textChanged(String raw) {
    if (state.isSubmitting) return;
    emit(
      ComposerState(draft: analyzePostDraft(raw), status: ComposerStatus.editing),
    );
  }

  Future<void> submit() async {
    if (!state.canSubmit) return;
    final text = state.draft.text;
    if (_keyText != text) {
      _key = null;
    }
    final key = _key ??= _uuid.v4();
    _keyText = text;

    _pending.add(
      PendingPost(
        localId: key,
        text: text,
        author: _author,
        createdAt: _clock(),
      ),
    );
    emit(state.copyWith(status: ComposerStatus.submitting, clearError: true));
    try {
      await _repository.createPost(idempotencyKey: key, text: text);
      _key = null;
      _keyText = null;
      _pending.remove(key);
      if (!isClosed) emit(state.copyWith(status: ComposerStatus.posted));
    } on AppException catch (e) {
      _fail(key, e);
    } catch (_) {
      _fail(key, const UnknownApiException('Something went wrong.'));
    }
  }

  void _fail(String key, AppException error) {
    // Rollback: the optimistic item leaves Home/profile; the text stays in
    // the field and the key stays for the retry.
    _pending.remove(key);
    if (isClosed) return;
    emit(state.copyWith(status: ComposerStatus.editing, error: error));
  }

  /// Marks the error as handled (shown), keeping the draft.
  void errorShown() {
    if (state.error != null) emit(state.copyWith(clearError: true));
  }
}
