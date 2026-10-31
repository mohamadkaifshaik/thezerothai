import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:uuid/uuid.dart';

import '../../../../core/network/app_exception.dart';
import '../../../../gen/dzeroth/common/v1/common.pb.dart' as common;
import '../../../../gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import '../../../../gen/dzeroth/posts/v1/posts.pbenum.dart' show ReplyPolicy;
import '../../../media/presentation/bloc/attachments_cubit.dart';
import '../../data/posts_repository.dart';
import '../../domain/composer_attachment_rules.dart';
import '../../domain/composer_draft.dart' show DraftPoll;
import '../../domain/poll_rules.dart';
import '../../domain/posts_feature_flag.dart';
import '../../domain/post_text_rules.dart';
import '../../domain/reply_audience.dart';
import '../../domain/schedule_rules.dart';
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
    this.replyAudience = ReplyAudience.everyone,
    this.replyPolicyNotApplied = false,
    this.scheduledAt,
    this.scheduledNotice,
    this.poll,
    this.pollDurationClamped = false,
    this.pollNotAdded = false,
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

  /// Who may reply to this post once it is created (ADR-0021 D2). Everyone
  /// unless the user chose otherwise; only chosen when
  /// [ComposerCubit.canChooseReplyAudience].
  final ReplyAudience replyAudience;

  /// Set with [ComposerStatus.posted] when the post the server echoed does
  /// not carry the audience that was sent (ADR-0021 L-1): the screen tells
  /// the user once and nothing else changes.
  final bool replyPolicyNotApplied;

  /// The time the post is to be sent (CMP-D6, ADR-0021 D4): a UTC instant at
  /// minute precision, or null for "post now". Set only while
  /// [ComposerCubit.canSchedule]; the primary button then reads "Schedule".
  final DateTime? scheduledAt;

  /// Set when a SchedulePost succeeded: the item as the server stored it (its
  /// `publish_at` is the time to show). The state is otherwise reset to an
  /// empty composer; the screen shows the notice once and calls
  /// [ComposerCubit.scheduledNoticeShown].
  final pb.ScheduledPost? scheduledNotice;

  /// The poll being built (ADR-0029, W6-12), as typed: choice rows may be
  /// empty while editing. Null: no poll. It is mapped to the generated
  /// `PollDraft` only by the repository; drafts (W6-14) keep the same model.
  final DraftPoll? poll;

  /// The length the user asked for was under the 5 minute minimum and was
  /// raised to it: the builder says so until the next length change.
  final bool pollDurationClamped;

  /// Set with [ComposerStatus.posted] when a poll was sent but the post the
  /// server echoed has none (ADR-0029 L-1): the screen warns once and offers
  /// to delete the post.
  final bool pollNotAdded;

  bool get hasPoll => poll != null;
  bool get isScheduling => scheduledAt != null;
  bool get isSubmitting => status == ComposerStatus.submitting;
  bool get canSubmit {
    if (status != ComposerStatus.editing) return false;
    // A poll needs its question (the post text) and every rule to hold; it
    // never travels with photos.
    final poll = this.poll;
    if (poll != null) {
      return !hasAttachments && draft.canPost && analyzePoll(poll).valid;
    }
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
    ReplyAudience? replyAudience,
    bool? replyPolicyNotApplied,
    DateTime? scheduledAt,
    DraftPoll? poll,
    bool? pollDurationClamped,
    bool? pollNotAdded,
    bool clearPoll = false,
    bool clearError = false,
    bool clearCreated = false,
    bool clearScheduledAt = false,
    bool clearScheduledNotice = false,
  }) => ComposerState(
    draft: draft ?? this.draft,
    status: status ?? this.status,
    error: clearError ? null : (error ?? this.error),
    created: clearCreated ? null : (created ?? this.created),
    hasAttachments: hasAttachments ?? this.hasAttachments,
    attachmentsReady: attachmentsReady ?? this.attachmentsReady,
    uploadFailed: clearError ? false : (uploadFailed ?? this.uploadFailed),
    replyAudience: replyAudience ?? this.replyAudience,
    replyPolicyNotApplied: replyPolicyNotApplied ?? this.replyPolicyNotApplied,
    scheduledAt: clearScheduledAt ? null : (scheduledAt ?? this.scheduledAt),
    scheduledNotice: clearScheduledNotice ? null : scheduledNotice,
    poll: clearPoll ? null : (poll ?? this.poll),
    pollDurationClamped: clearPoll
        ? false
        : (pollDurationClamped ?? this.pollDurationClamped),
    pollNotAdded: pollNotAdded ?? this.pollNotAdded,
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
    this.quoteOfPostId = '',
    AttachmentsCubit? attachments,
    this.replyAudienceEnabled = false,
    this.scheduleEnabled = false,
    this.pollsFlag = false,
    this.engagementOn = false,
    this.gifFlag = false,
    this.mediaOn = false,
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
  }) : quoteOfPostId = '',
       _repository = postsRepository,
       _pending = null,
       _author = null,
       _attachments = null,
       _onUnexpectedError = null,
       _uuid = uuid ?? const Uuid(),
       _clock = clock ?? DateTime.now,
       replyAudienceEnabled = false,
       scheduleEnabled = false,
       pollsFlag = false,
       engagementOn = false,
       gifFlag = false,
       mediaOn = false,
       super(ComposerState(draft: analyzePostDraft('')));

  /// The post being replied to; empty for a top-level post.
  final String replyToPostId;

  /// The post being quoted (ADR-0018, `CreatePost.quote_of_post_id`); empty
  /// for a plain post or a reply. A quote is a top-level post with the same
  /// 280 limit, text or photos, and an embed of the original.
  final String quoteOfPostId;

  /// `reply_audience` is on for this viewer (ADR-0021 D2). Only then, and
  /// only for a root post or a quote (never a reply), may the user pick who
  /// can reply; otherwise the request always carries UNSPECIFIED.
  final bool replyAudienceEnabled;

  /// Also false once the server answered FEATURE_DISABLED for it (the gate
  /// remembers that until the next `GetMe`).
  bool get canChooseReplyAudience =>
      replyAudienceEnabled &&
      replyToPostId.isEmpty &&
      _repository.subFeatureEnabled(kFeatureReplyAudience);

  /// `posts` and `scheduled_posts` are both on for this viewer (CMP-D6,
  /// ADR-0021 D4). Only then, and only for a new root post, may the user
  /// schedule it.
  final bool scheduleEnabled;

  /// Whether the Schedule action is offered: a new root post only (the request
  /// has no reply, quote or poll field), and not once the server answered
  /// FEATURE_DISABLED for `scheduled_posts` (the gate remembers that until the
  /// next `GetMe`).
  bool get canSchedule =>
      scheduleEnabled &&
      replyToPostId.isEmpty &&
      quoteOfPostId.isEmpty &&
      _repository.subFeatureEnabled(kFeatureScheduledPosts);

  /// The raw flags the composer's toolbar rules read (ADR-0029 D12): `polls`
  /// and `engagement` for the poll, `gif` and `media` for the GIF button. The
  /// gate's session-long FEATURE_DISABLED memory is added by [rules].
  final bool pollsFlag;
  final bool engagementOn;
  final bool gifFlag;
  final bool mediaOn;

  /// The one answer to "which toolbar buttons are on" (W6-11): the screen and
  /// every cubit guard read it, none restates a rule. Reads the gate live, so
  /// a `FEATURE_DISABLED feature=polls` hides the button for the session.
  ComposerAttachmentRules get rules => ComposerAttachmentRules(
    flagPolls: pollsFlag && _repository.subFeatureEnabled(kFeaturePolls),
    engagementOn: engagementOn,
    flagGif: gifFlag,
    mediaOn: mediaOn,
    isReply: replyToPostId.isNotEmpty,
    isQuote: quoteOfPostId.isNotEmpty,
    hasPhotos: state.hasAttachments,
    hasPoll: state.hasPoll,
    // A time is only in force while the composer can still schedule.
    scheduled: state.isScheduling && canSchedule,
  );

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
        replyAudience: state.replyAudience,
        scheduledAt: state.scheduledAt,
        poll: state.poll,
        pollDurationClamped: state.pollDurationClamped,
      ),
    );
  }

  /// Opens the poll builder with two empty choices and a one day length.
  /// Ignored when the rules do not offer a poll now (flag off, a reply or
  /// quote, photos, a GIF or a schedule is set), when one is already open and
  /// while the post is being sent.
  void pollAdded() {
    if (state.isSubmitting || state.hasPoll) return;
    final r = rules;
    if (!r.showPoll || r.poll != ComposerBlock.none) return;
    emit(state.copyWith(poll: newDraftPoll(), clearError: true));
  }

  /// "Remove poll": back to a plain post. Always allowed unless sending.
  void pollRemoved() {
    if (state.isSubmitting || !state.hasPoll) return;
    emit(state.copyWith(clearPoll: true, clearError: true));
  }

  /// Sets the text of choice [index] as typed (kept raw; the rules run on it
  /// when the poll is analysed).
  void pollChoiceChanged(int index, String text) {
    final poll = state.poll;
    if (poll == null || state.isSubmitting) return;
    if (index < 0 || index >= poll.choices.length) return;
    if (poll.choices[index] == text) return;
    final choices = [...poll.choices]..[index] = text;
    emit(
      state.copyWith(
        poll: DraftPoll(
          choices: choices,
          durationMinutes: poll.durationMinutes,
        ),
        clearError: true,
      ),
    );
  }

  /// "Add a choice": an empty row, up to [kPollMaxChoices].
  void pollChoiceAdded() {
    final poll = state.poll;
    if (poll == null || state.isSubmitting) return;
    if (poll.choices.length >= kPollMaxChoices) return;
    emit(
      state.copyWith(
        poll: DraftPoll(
          choices: [...poll.choices, ''],
          durationMinutes: poll.durationMinutes,
        ),
      ),
    );
  }

  /// Removes choice [index]; a poll keeps at least [kPollMinChoices] rows.
  void pollChoiceRemoved(int index) {
    final poll = state.poll;
    if (poll == null || state.isSubmitting) return;
    if (poll.choices.length <= kPollMinChoices) return;
    if (index < 0 || index >= poll.choices.length) return;
    emit(
      state.copyWith(
        poll: DraftPoll(
          choices: [...poll.choices]..removeAt(index),
          durationMinutes: poll.durationMinutes,
        ),
      ),
    );
  }

  /// Sets the length in whole minutes. Under [kPollMinMinutes] it is raised
  /// to the minimum and [ComposerState.pollDurationClamped] says so; over
  /// [kPollMaxMinutes] (7 days) it is cut to the maximum.
  void pollDurationChanged(int totalMinutes) {
    final poll = state.poll;
    if (poll == null || state.isSubmitting) return;
    final clamped = totalMinutes < kPollMinMinutes;
    final minutes = totalMinutes.clamp(kPollMinMinutes, kPollMaxMinutes);
    if (minutes == poll.durationMinutes &&
        clamped == state.pollDurationClamped) {
      return;
    }
    emit(
      state.copyWith(
        poll: DraftPoll(choices: poll.choices, durationMinutes: minutes),
        pollDurationClamped: clamped,
      ),
    );
  }

  /// Sets (or, with null, removes) the time to send the post at. [publishAt]
  /// may be local or UTC; it is kept as a UTC instant cut to the minute, like
  /// the server stores it. Setting a time is ignored when scheduling is not
  /// offered; removing one is always allowed (a schedule must never be stuck
  /// on a composer that can no longer schedule). Both are ignored while the
  /// post is being sent. The dialog has checked the window; the server
  /// decides (VALIDATION `publish_at` reopens the dialog).
  void scheduleChanged(DateTime? publishAt) {
    if (state.isSubmitting) return;
    if (publishAt != null && !canSchedule) return;
    // A poll cannot be scheduled (SchedulePost has no poll field, ADR-0029
    // F5): the same rules object that disables the button refuses it here.
    if (publishAt != null && rules.schedule != ComposerBlock.none) return;
    final next = publishAt == null
        ? null
        : truncatedToMinute(publishAt.toUtc());
    if (next == state.scheduledAt) return;
    emit(
      next == null
          ? state.copyWith(clearScheduledAt: true, clearError: true)
          : state.copyWith(scheduledAt: next, clearError: true),
    );
  }

  /// Scheduling may have been switched off while this composer was open (the
  /// gate learned a FEATURE_DISABLED elsewhere, for example from the Scheduled
  /// list): drop the time then, so the screen never offers a schedule that
  /// cannot be sent. The screen calls this when it comes back from the list.
  void scheduleAvailabilityChecked() {
    if (state.isSubmitting || state.scheduledAt == null || canSchedule) return;
    emit(state.copyWith(clearScheduledAt: true));
  }

  /// The "Will send on" notice was shown: forget it.
  void scheduledNoticeShown() {
    if (state.scheduledNotice != null) {
      emit(state.copyWith(clearScheduledNotice: true));
    }
  }

  /// Picks who can reply (the "Who can reply?" sheet). Ignored for a reply,
  /// while the feature is off and while the post is being sent.
  void replyAudienceChanged(ReplyAudience audience) {
    if (!canChooseReplyAudience || state.isSubmitting) return;
    if (audience == state.replyAudience) return;
    emit(state.copyWith(replyAudience: audience));
  }

  /// The policy the next CreatePost carries: UNSPECIFIED unless a narrower
  /// audience is allowed and chosen (an explicit Everyone is UNSPECIFIED too).
  ReplyPolicy get _policyToSend => canChooseReplyAudience
      ? state.replyAudience.wire
      : ReplyPolicy.REPLY_POLICY_UNSPECIFIED;

  static const _noUploads = UploadedAttachments(mediaIds: [], altTexts: []);

  bool get _hasAttached => _attachments != null && !_attachments.state.isEmpty;

  /// Uploads the attached images first (P4) and returns their ids and alt
  /// texts (empty without attachments). Null when the upload failed or the
  /// screen went away: the failure is then already in the state, and the
  /// caller just stops. Shared by Post and Schedule.
  Future<UploadedAttachments?> _uploadAttached() async {
    final attachments = _attachments!;
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
      return null;
    }
    try {
      final uploaded = await attachments.uploadAll();
      // The screen may have gone while the photos uploaded: never create
      // a post nobody is waiting for (and never one that lost its photos).
      return isClosed ? null : uploaded;
    } on AppException catch (e) {
      // Already reported where it happened (repository / uploader): never
      // report an upload failure a second time here.
      if (isClosed) return null;
      emit(
        state.copyWith(
          status: ComposerStatus.editing,
          error: e,
          uploadFailed: true,
        ),
      );
      return null;
    } catch (error, stack) {
      _onUnexpectedError?.call(error, stack);
      if (isClosed) return null;
      emit(
        state.copyWith(
          status: ComposerStatus.editing,
          error: const UnknownApiException('Something went wrong.'),
          uploadFailed: true,
        ),
      );
      return null;
    }
  }

  /// What makes two requests the same for the server: text, media ids, alt
  /// texts and the audience. Keys are remembered per such body.
  String _bodyKey(
    String text,
    List<String> mediaIds,
    List<String> altTexts,
    ReplyPolicy policy, [
    DraftPoll? poll,
  ]) {
    var body = mediaIds.isEmpty
        ? text
        : '$text\u0001${mediaIds.join(',')}\u0001${altTexts.join('\u0002')}';
    // The poll is part of the request (ADR-0029 D2). Keyed on the NORMALISED
    // labels and the length, like the server's hash: an edit that changes
    // only spacing is the same request and reuses its key; any real change
    // gets its own.
    if (poll != null) {
      body =
          '$body\u0001poll=${analyzePoll(poll).stored.join('\u001f')}'
          '\u0001dur=${poll.durationMinutes}';
    }
    // A different audience is a different request body for the server.
    return policy == ReplyPolicy.REPLY_POLICY_UNSPECIFIED
        ? body
        : 'p:${policy.value}\u0001$body';
  }

  /// The idempotency key of [intent], created on first use and reused by
  /// every retry of the same request. Least recently used: a reused intent
  /// moves to the end, so the oldest UNUSED one is dropped first (a request
  /// that may exist on the server must keep its key while others come and go).
  String _keyFor(String intent) {
    final key = _keys.remove(intent) ?? _uuid.v4();
    _keys[intent] = key;
    while (_keys.length > _maxRememberedKeys) {
      _keys.remove(_keys.keys.first);
    }
    _keyText = intent;
    return key;
  }

  Future<void> submit() async {
    if (!state.canSubmit) return;
    final publishAt = state.scheduledAt;
    // SchedulePost has no poll field: a poll never takes that path (the
    // rules already keep the two apart; this is the last guard).
    if (publishAt != null && !state.hasPoll) return _submitScheduled(publishAt);
    final text = state.draft.text;
    final poll = state.poll;
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
    // No await without photos: the optimistic row appears in the same turn.
    final uploaded = _hasAttached ? await _uploadAttached() : _noUploads;
    if (uploaded == null) return;
    final mediaIds = uploaded.mediaIds;
    final altTexts = uploaded.altTexts;

    final policy = _policyToSend;
    final bodyWithPolicy = _bodyKey(text, mediaIds, altTexts, policy, poll);
    // A quote and a plain post with the same body are different requests.
    final intent = quoteOfPostId.isEmpty
        ? bodyWithPolicy
        : 'q:$quoteOfPostId\u0001$bodyWithPolicy';
    final key = _keyFor(intent);

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
        quoteOfPostId: quoteOfPostId,
        mediaIds: mediaIds,
        mediaAltTexts: altTexts,
        replyPolicy: policy,
        poll: poll == null
            ? null
            : DraftPoll(
                choices: analyzePoll(poll).stored,
                durationMinutes: poll.durationMinutes,
              ),
      );
      _keys.remove(intent);
      _keyText = null;
      pending?.remove(key);
      if (!isClosed) {
        // Echo check (ADR-0021 L-1): an older revision may have dropped the
        // field, leaving the post open to everyone. Warn; never fail.
        final notApplied = !replyPoliciesMatch(
          policy,
          created.post.replyPolicy,
        );
        emit(
          state.copyWith(
            status: ComposerStatus.posted,
            created: created,
            replyPolicyNotApplied: notApplied,
            // Echo check (ADR-0029 L-1): an older revision drops the field
            // and posts the question alone.
            pollNotAdded: poll != null && !created.post.hasPoll(),
          ),
        );
      }
    } on AppException catch (e) {
      _fail(key, e);
    } catch (_) {
      _fail(key, const UnknownApiException('Something went wrong.'));
    }
  }

  /// Schedules the post for [publishAt] (CMP-D6): the same uploads as Post,
  /// then `SchedulePost` with a key kept per request (text, media, audience
  /// AND time). A retry of the same request reuses its key, also after a
  /// LIMIT_REACHED / QUOTA_EXCEEDED that may have been a near-simultaneous
  /// duplicate of a call that succeeded (review m1), and also when the 2 minute
  /// lead has passed meanwhile: the server then answers with the stored item,
  /// which is why no local time check runs here. Any edit (text, photos,
  /// audience, time) is a different request and gets its own key. Nothing is
  /// added to a feed: the post exists once the server publishes it.
  ///
  /// On success the composer is reset to empty; [ComposerState.scheduledNotice]
  /// carries the stored item for the one "Your post will be sent on ..." toast.
  Future<void> _submitScheduled(DateTime publishAt) async {
    if (!canSchedule) {
      emit(
        state.copyWith(
          error: const FeatureDisabledException(
            'Scheduling is not available.',
            feature: kFeatureScheduledPosts,
          ),
          clearScheduledAt: true,
        ),
      );
      return;
    }
    final text = state.draft.text;
    emit(
      state.copyWith(
        status: ComposerStatus.submitting,
        clearError: true,
        clearCreated: true,
      ),
    );
    // No await without photos: the optimistic row appears in the same turn.
    final uploaded = _hasAttached ? await _uploadAttached() : _noUploads;
    if (uploaded == null) return;
    final policy = _policyToSend;
    final intent =
        's:${publishAt.millisecondsSinceEpoch}\u0001'
        '${_bodyKey(text, uploaded.mediaIds, uploaded.altTexts, policy)}';
    final key = _keyFor(intent);
    try {
      final scheduled = await _repository.schedulePost(
        idempotencyKey: key,
        text: text,
        publishAt: publishAt,
        mediaIds: uploaded.mediaIds,
        mediaAltTexts: uploaded.altTexts,
        replyPolicy: policy,
      );
      _keys.remove(intent);
      _keyText = null;
      if (isClosed) return;
      emit(
        ComposerState(draft: analyzePostDraft(''), scheduledNotice: scheduled),
      );
      // The images now belong to the scheduled item.
      _attachments?.clear();
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
    // The server refused the audience (flag off): fall back to Everyone so
    // the user can still post (the gate also stops sending it).
    final audienceRefused =
        error is FeatureDisabledException &&
        error.feature == kFeatureReplyAudience;
    final pollsRefused =
        error is FeatureDisabledException && error.feature == kFeaturePolls;
    emit(
      state.copyWith(
        status: ComposerStatus.editing,
        error: error,
        replyAudience: audienceRefused ? ReplyAudience.everyone : null,
        // Any answer that turned scheduling off (the sub-feature, or the whole
        // of posts) takes the time with it: the button goes back to "Post".
        clearScheduledAt: !canSchedule,
        // The server turned polls off: the builder goes with it, the text
        // stays, so the user can still post.
        clearPoll: pollsRefused,
      ),
    );
  }

  /// Marks the error as handled (shown), keeping the draft.
  void errorShown() {
    if (state.error != null) emit(state.copyWith(clearError: true));
  }
}
