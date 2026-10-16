import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:uuid/uuid.dart';

import '../../../../core/network/app_exception.dart';
import '../../../../gen/dzeroth/common/v1/common.pb.dart' as common;
import '../../../../gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import '../../../media/presentation/bloc/attachments_cubit.dart';
import '../../data/posts_repository.dart';
import '../../domain/posts_feature_flag.dart';
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
    this.hasAttachments = false,
    this.attachmentsReady = true,
    this.uploadFailed = false,
  });

  final PostDraft draft;
  final ComposerStatus status;

  /// The server's view of the post, set with [ComposerStatus.posted] (the
  /// thread screen appends a new reply from it with no refetch).
  final pb.PostView? created;

  /// The last failed submit, shown once (snackbar / verify prompt) and
  /// cleared by the next edit or submit.
  final AppException? error;

  /// At least one image is attached (P4). An image-only post is valid
  /// (empty text is accepted exactly when an image is attached, plan D2).
  final bool hasAttachments;

  /// Every attached image is usable and none is being processed or sent.
  final bool attachmentsReady;

  /// [error] came from the photo upload step (not CreatePost), so the UI
  /// words it for photos.
  final bool uploadFailed;

  bool get isSubmitting => status == ComposerStatus.submitting;
  bool get canSubmit {
    if (status != ComposerStatus.editing) return false;
    if (hasAttachments) {
      return attachmentsReady &&
          (draft.canPost || draft.problem == PostDraftProblem.empty);
    }
    return draft.canPost;
  }

  ComposerState copyWith({
    PostDraft? draft,
    ComposerStatus? status,
    AppException? error,
    pb.PostView? created,
    bool? hasAttachments,
    bool? attachmentsReady,
    bool? uploadFailed,
    bool clearError = false,
    bool clearCreated = false,
  }) => ComposerState(
    draft: draft ?? this.draft,
    status: status ?? this.status,
    error: clearError ? null : (error ?? this.error),
    created: clearCreated ? null : (created ?? this.created),
    hasAttachments: hasAttachments ?? this.hasAttachments,
    attachmentsReady: attachmentsReady ?? this.attachmentsReady,
    uploadFailed: clearError ? false : (uploadFailed ?? this.uploadFailed),
  );
}

/// Drives the compose screen (T16): live D9 counter, optimistic insert via
/// [PendingPostsCubit], rollback on error, and one idempotency key per
/// intent.
///
/// The key is generated at the first submit of a text and reused by every
/// retry of that same text (a dropped response can never create a second
/// post), even after the user edited to another text and back: keys are kept
/// per submitted intent (text + attached media ids + alt texts), so
/// edit-and-revert cannot mint a second key for a post that may already
/// exist. A different intent gets its own key (the server would answer
/// IDEMPOTENCY_KEY_REUSED for a different body), and an intent's key is
/// dropped once its post succeeded. Attached images are uploaded first
/// (P4): the uploader reuses finished uploads on retry, so the media ids and
/// therefore the key stay the same.
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
    AttachmentsCubit? attachments,
    void Function(Object error, StackTrace stack)? onUnexpectedError,
    Uuid? uuid,
    DateTime Function()? clock,
  }) : replyToPostId = '',
       _repository = postsRepository,
       _pending = pending,
       _author = author,
       _attachments = attachments,
       _onUnexpectedError = onUnexpectedError,
       _uuid = uuid ?? const Uuid(),
       _clock = clock ?? DateTime.now,
       super(ComposerState(draft: analyzePostDraft(''))) {
    _watchAttachments();
  }

  /// A reply to [replyToPostId] (P3 thread screen). Replies never appear on
  /// Home, so there is no optimistic item here: the thread screen shows its
  /// own pending row while [ComposerState.isSubmitting].
  ComposerCubit.reply({
    required PostsRepository postsRepository,
    required this.replyToPostId,
    Uuid? uuid,
    DateTime Function()? clock,
  }) : _repository = postsRepository,
       _pending = null,
       _author = null,
       _attachments = null,
       _onUnexpectedError = null,
       _uuid = uuid ?? const Uuid(),
       _clock = clock ?? DateTime.now,
       super(ComposerState(draft: analyzePostDraft('')));

  /// The post being replied to; empty for a top-level post.
  final String replyToPostId;

  final PostsRepository _repository;
  final PendingPostsCubit? _pending;
  final common.AuthorSnapshot? _author;
  final AttachmentsCubit? _attachments;
  final void Function(Object error, StackTrace stack)? _onUnexpectedError;
  StreamSubscription<AttachmentsState>? _attachmentsSub;
  final Uuid _uuid;
  final DateTime Function() _clock;

  /// Idempotency key per submitted text, insertion-ordered and bounded.
  final Map<String, String> _keys = {};
  String? _keyText;

  /// The key of the current intent, for tests and diagnostics.
  @visibleForTesting
  String? get currentKey => _keyText == null ? null : _keys[_keyText];

  void _watchAttachments() {
    final attachments = _attachments;
    if (attachments == null) return;
    _attachmentsSub = attachments.stream.listen((a) {
      if (isClosed) return;
      final hasAttachments = !a.isEmpty;
      final ready = a.isEmpty || (a.isSendable && !a.isBusy);
      // Upload progress re-emits attachments many times a second; the
      // composer only cares when one of these two answers changes.
      if (hasAttachments == state.hasAttachments &&
          ready == state.attachmentsReady) {
        return;
      }
      emit(
        state.copyWith(hasAttachments: hasAttachments, attachmentsReady: ready),
      );
    });
  }

  @override
  Future<void> close() async {
    await _attachmentsSub?.cancel();
    return super.close();
  }

  void textChanged(String raw) {
    if (state.isSubmitting) return;
    emit(
      ComposerState(
        draft: analyzePostDraft(raw),
        status: ComposerStatus.editing,
        hasAttachments: state.hasAttachments,
        attachmentsReady: state.attachmentsReady,
      ),
    );
  }

  Future<void> submit() async {
    if (!state.canSubmit) return;
    final text = state.draft.text;
    emit(
      state.copyWith(
        status: ComposerStatus.submitting,
        clearError: true,
        clearCreated: true,
      ),
    );

    // On-device previews for the optimistic row (taken before upload).
    final thumbnails = [
      for (final a in _attachments?.state.items ?? const <Attachment>[])
        if (a.previewBytes != null) a.previewBytes!,
    ];
    var mediaIds = const <String>[];
    var altTexts = const <String>[];
    final attachments = _attachments;
    if (attachments != null && !attachments.state.isEmpty) {
      // A CreatePost with media is refused while the media sub-feature is
      // off: do not spend upload quota first.
      if (!_repository.subFeatureEnabled(kPostsSubFeatureMedia)) {
        emit(
          state.copyWith(
            status: ComposerStatus.editing,
            error: const FeatureDisabledException(
              'Photos are not available.',
              feature: kPostsSubFeatureMedia,
            ),
          ),
        );
        return;
      }
      try {
        final uploaded = await attachments.uploadAll();
        mediaIds = uploaded.mediaIds;
        altTexts = uploaded.altTexts;
        // The screen may have gone while the photos uploaded: never create
        // a post nobody is waiting for (and never one that lost its photos).
        if (isClosed) return;
      } on AppException catch (e) {
        // Already reported where it happened (repository / uploader): never
        // report an upload failure a second time here.
        if (isClosed) return;
        emit(
          state.copyWith(
            status: ComposerStatus.editing,
            error: e,
            uploadFailed: true,
          ),
        );
        return;
      } catch (error, stack) {
        _onUnexpectedError?.call(error, stack);
        if (isClosed) return;
        emit(
          state.copyWith(
            status: ComposerStatus.editing,
            error: const UnknownApiException('Something went wrong.'),
            uploadFailed: true,
          ),
        );
        return;
      }
    }

    final intent = mediaIds.isEmpty
        ? text
        : '$text\u0001${mediaIds.join(',')}\u0001${altTexts.join('\u0002')}';
    final key = _keys.putIfAbsent(intent, _uuid.v4);
    if (_keys.length > _maxRememberedKeys) _keys.remove(_keys.keys.first);
    _keyText = intent;

    final pending = _pending;
    final author = _author;
    if (pending != null && author != null) {
      pending.add(
        PendingPost(
          localId: key,
          text: text,
          author: author,
          createdAt: _clock(),
          thumbnails: thumbnails,
        ),
      );
    }
    try {
      final created = await _repository.createPost(
        idempotencyKey: key,
        text: text,
        replyToPostId: replyToPostId,
        mediaIds: mediaIds,
        mediaAltTexts: altTexts,
      );
      _keys.remove(intent);
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
