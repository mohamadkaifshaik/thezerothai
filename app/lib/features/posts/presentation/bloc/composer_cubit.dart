import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:uuid/uuid.dart';

import '../../../../core/network/app_exception.dart';
import '../../../../core/storage/session_epoch.dart';
import '../../../../core/telemetry/analytics_event.dart';
import '../../../../core/telemetry/usage_reporter.dart';
import '../../../../gen/dzeroth/common/v1/common.pb.dart' as common;
import '../../../../gen/dzeroth/communities/v1/communities.pb.dart' as pbc;
import '../../../../gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import '../../../../gen/dzeroth/posts/v1/posts.pbenum.dart' show ReplyPolicy;
import '../../../communities/data/communities_repository.dart';
import '../../../communities/domain/communities_feature_flag.dart';
import '../../../communities/domain/community_role.dart';
import '../../../media/presentation/bloc/attachments_cubit.dart';
import '../../data/posts_repository.dart';
import '../../domain/compose_audience.dart';
import '../../domain/composer_attachment_rules.dart';
import '../../data/drafts_repository.dart';
import '../../domain/composer_draft.dart';
import '../../domain/poll_rules.dart';
import '../../domain/posts_feature_flag.dart';
import '../../domain/post_text_rules.dart';
import '../../domain/reply_audience.dart';
import '../../domain/schedule_rules.dart';
import 'pending_posts_cubit.dart';

enum ComposerStatus { editing, submitting, posted }

/// The answer of [ComposerCubit.loadSavedDraft].
enum DraftLoadResult {
  loaded,

  /// Missing, another account's, or unreadable.
  gone,

  /// The draft has a poll and photos or a GIF are attached.
  blockedByMedia,
}

/// Why a draft send was stopped before, or after, the RPC without an error
/// message of its own. The screen asks the
/// user what to do; nothing is sent until they choose.
enum SendConflict {
  /// The server knows the key with another body: an earlier version of this
  /// post was sent. Offers "View profile" and "Post this version too".
  earlierVersionSent,

  /// The draft row is gone: another composer sent it, or it was deleted.
  /// Only "View profile".
  draftGone,

  /// A post may already exist and the user now asks to schedule it.
  pendingPost,

  /// A scheduled post may already exist and the user now asks to post it.
  pendingSchedule,

  /// The stored key is older than its window: we cannot tell whether the
  /// earlier send landed.
  unconfirmed;

  /// Whether the user may override with a new key.
  bool get canSendAnyway => this != draftGone;
}

/// What leaving the composer needs.
enum LeaveAction {
  /// Nothing is lost: leave.
  none,

  /// "Save post?" (Save, Discard, keep editing): unsent content that is not
  /// yet saved as it stands.
  savePrompt,

  /// Only media is attached (or unsent posts are off): the old "Discard this
  /// post?" question, because media is never kept.
  discardMedia,
}

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
    this.sendConflict,
    this.audience = ComposeAudience.everyone,
    this.communityChoices = const [],
    this.audienceNotice,
    this.communityNotApplied = false,
    this.sessionEnded = false,
  });

  final PostDraft draft;
  final ComposerStatus status;

  /// The server's view of the post, set with [ComposerStatus.posted] (the
  /// thread screen appends a new reply from it with no refetch).
  final pb.PostView? created;

  /// The last failed submit, shown once (snackbar / verify prompt) and
  /// cleared by the next edit or submit.
  final AppException? error;

  /// At least one image is attached. An image-only post is valid
  /// (empty text is accepted exactly when an image is attached, plan D2).
  final bool hasAttachments;

  /// Every attached image is usable and none is being processed or sent.
  final bool attachmentsReady;

  /// [error] came from the photo upload step (not CreatePost), so the UI
  /// words it for photos.
  final bool uploadFailed;

  /// Who may reply to this post once it is created. Everyone
  /// unless the user chose otherwise; only chosen when
  /// [ComposerCubit.canChooseReplyAudience].
  final ReplyAudience replyAudience;

  /// Set with [ComposerStatus.posted] when the post the server echoed does
  /// not carry the audience that was sent: the screen tells
  /// the user once and nothing else changes.
  final bool replyPolicyNotApplied;

  /// The time the post is to be sent: a UTC instant at
  /// minute precision, or null for "post now". Set only while
  /// [ComposerCubit.canSchedule]; the primary button then reads "Schedule".
  final DateTime? scheduledAt;

  /// Set when a SchedulePost succeeded: the item as the server stored it (its
  /// `publish_at` is the time to show). The state is otherwise reset to an
  /// empty composer; the screen shows the notice once and calls
  /// [ComposerCubit.scheduledNoticeShown].
  final pb.ScheduledPost? scheduledNotice;

  /// The poll being built, as typed: choice rows may be
  /// empty while editing. Null: no poll. It is mapped to the generated
  /// `PollDraft` only by the repository; drafts keep the same model.
  final DraftPoll? poll;

  /// The length the user asked for was under the 5 minute minimum and was
  /// raised to it: the builder says so until the next length change.
  final bool pollDurationClamped;

  /// Set with [ComposerStatus.posted] when a poll was sent but the post the
  /// server echoed has none: the screen warns once and offers
  /// to delete the post.
  final bool pollNotAdded;

  /// A draft send that needs the user's decision, shown once and
  /// cleared by [ComposerCubit.sendConflictShown].
  final SendConflict? sendConflict;

  /// Where the post goes: Everyone, or one joined community. Sent as
  /// `community_id` only while [ComposerCubit.canChooseCommunity].
  final ComposeAudience audience;

  /// The communities the caller may post into (the picker's rows), empty until
  /// loaded or when there is none.
  final List<pbc.Community> communityChoices;

  /// The composer put the audience back to Everyone: shown once by the screen
  /// ([ComposerCubit.audienceNoticeShown]).
  final AudienceNotice? audienceNotice;

  /// Set with [ComposerStatus.posted] when a community post came back with no
  /// `community` (an older server dropped the field): the screen
  /// warns once and offers to delete the post.
  final bool communityNotApplied;

  /// The session this composer was opened in has ended (a sign-out or an
  /// account switch): nothing is sent or saved any more, and the screen
  /// leaves.
  final bool sessionEnded;

  bool get hasPoll => poll != null;
  bool get isScheduling => scheduledAt != null;
  bool get isSubmitting => status == ComposerStatus.submitting;
  bool get canSubmit {
    if (status != ComposerStatus.editing || sessionEnded) return false;
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
    SendConflict? sendConflict,
    ComposeAudience? audience,
    List<pbc.Community>? communityChoices,
    AudienceNotice? audienceNotice,
    bool clearAudienceNotice = false,
    bool? communityNotApplied,
    bool? sessionEnded,
    bool clearSendConflict = false,
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
    sendConflict: clearSendConflict
        ? null
        : (sendConflict ?? this.sendConflict),
    audience: audience ?? this.audience,
    communityChoices: communityChoices ?? this.communityChoices,
    audienceNotice: clearAudienceNotice
        ? null
        : (audienceNotice ?? this.audienceNotice),
    communityNotApplied: communityNotApplied ?? this.communityNotApplied,
    sessionEnded: sessionEnded ?? this.sessionEnded,
  );
}

/// Drives the compose screen: live D9 counter, optimistic insert via
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
/// dropped once its post succeeded. Attached images are uploaded first:
/// the uploader reuses finished uploads on retry, so the media ids and
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
    this.communitiesEnabled = false,
    CommunitiesRepository? communities,
    String initialCommunityId = '',
    void Function(Object error, StackTrace stack)? onUnexpectedError,
    Uuid? uuid,
    DateTime Function()? clock,
    DraftsRepository? drafts,
    String uid = '',
    ComposerDraft? initialDraft,
    UsageReporter usage = const UsageReporter.none(),
    SessionEpoch? sessionEpoch,
  }) : replyToPostId = '',
       _session = sessionEpoch ?? SessionEpoch(),
       _communities = communities,
       _pendingCommunityId = initialCommunityId.isNotEmpty
           ? initialCommunityId
           : (initialDraft?.communityId ?? ''),
       _usage = usage,
       _repository = postsRepository,
       _pending = pending,
       _author = author,
       _attachments = attachments,
       _onUnexpectedError = onUnexpectedError,
       _uuid = uuid ?? const Uuid(),
       _clock = clock ?? DateTime.now,
       // Unsent posts are for a new root post only: never a quote, and a
       // reply has its own constructor.
       _drafts = quoteOfPostId.isEmpty && uid.isNotEmpty ? drafts : null,
       _draftUid = uid,
       _base = _baseDraft(uid, initialDraft, clock ?? DateTime.now),
       super(
         _initialState(
           initialDraft,
           pollsOffered: pollsFlag && engagementOn,
           audienceEnabled: replyAudienceEnabled,
         ),
       ) {
    _baseline = _base;
    _openedSession = _session.value;
    _sessionSub = _session.ended.listen((_) => _sessionHasEnded());
    _watchAttachments();
  }

  /// A reply to [replyToPostId] (thread screen). Replies never appear on
  /// Home, so there is no optimistic item here: the thread screen shows its
  /// own pending row while [ComposerState.isSubmitting].
  ComposerCubit.reply({
    required PostsRepository postsRepository,
    required this.replyToPostId,
    Uuid? uuid,
    DateTime Function()? clock,
    UsageReporter usage = const UsageReporter.none(),
  }) : quoteOfPostId = '',
       // A reply has no await before its RPC (no draft row, no photos).
       _session = SessionEpoch(),
       _usage = usage,
       _repository = postsRepository,
       _pending = null,
       _author = null,
       _attachments = null,
       _onUnexpectedError = null,
       _uuid = uuid ?? const Uuid(),
       _clock = clock ?? DateTime.now,
       replyAudienceEnabled = false,
       communitiesEnabled = false,
       _communities = null,
       _pendingCommunityId = '',
       scheduleEnabled = false,
       pollsFlag = false,
       engagementOn = false,
       gifFlag = false,
       mediaOn = false,
       _drafts = null,
       _draftUid = '',
       _base = _baseDraft('', null, clock ?? DateTime.now),
       super(ComposerState(draft: analyzePostDraft(''))) {
    _baseline = _base;
    _openedSession = _session.value;
  }

  static ComposerDraft _baseDraft(
    String uid,
    ComposerDraft? initial,
    DateTime Function() clock,
  ) =>
      initial ??
      ComposerDraft(
        id: DraftsRepository.newId(),
        uid: uid,
        text: '',
        createdAt: clock(),
        updatedAt: clock(),
      );

  static ComposerState _initialState(
    ComposerDraft? d, {
    required bool pollsOffered,
    required bool audienceEnabled,
  }) => d == null
      ? ComposerState(draft: analyzePostDraft(''))
      : ComposerState(
          draft: analyzePostDraft(d.text),
          // A poll or an audience the flags no longer offer is not loaded.
          poll: pollsOffered ? d.poll : null,
          replyAudience: audienceEnabled
              ? d.replyAudience
              : ReplyAudience.everyone,
        );

  final DraftsRepository? _drafts;
  final String _draftUid;

  /// The draft being written: its id, owner, creation time and the labels the
  /// composer has no control for (kept so a re-save does not clear them).
  /// Replaced by [loadDraft].
  ComposerDraft _base;

  /// The draft as opened (or the empty one): "changed since open" compares
  /// with it.
  late ComposerDraft _baseline;

  /// Stops autosaving once the draft was posted, scheduled or discarded.
  bool _draftDone = false;
  bool _loadingDraft = false;

  /// Unsent posts are in use: `drafts` is on (the screen passes a repository
  /// only then), for a new root post.
  bool get draftsActive => _drafts != null && !_draftDone && !_sessionOver;

  /// The draft's id (the same row until it is posted or discarded).
  String get draftId => _base.id;

  /// The composer's content as a draft row.
  ComposerDraft get currentDraft => _base.copyWith(
    text: state.draft.text,
    poll: state.poll,
    clearPoll: state.poll == null,
    replyAudience: state.replyAudience,
    communityId: _draftCommunity(state),
  );

  /// The community id a draft keeps: the chosen one, else the one still
  /// waiting to be matched with the caller's communities (so an autosave never
  /// erases it before the list has loaded).
  String _draftCommunity(ComposerState s) =>
      s.audience.isCommunity ? s.audience.communityId : _pendingCommunityId;

  /// What leaving the composer needs now (see [LeaveAction]).
  LeaveAction get leaveAction {
    // The account changed: nothing of it is kept or asked about.
    if (state.isSubmitting || _sessionOver) return LeaveAction.none;
    final media = state.hasAttachments;
    if (!draftsActive) {
      return media ? LeaveAction.discardMedia : LeaveAction.none;
    }
    final draft = currentDraft;
    if (draft.isEmpty) {
      return media ? LeaveAction.discardMedia : LeaveAction.none;
    }
    return hasUnsavedDraftChanges || media
        ? LeaveAction.savePrompt
        : LeaveAction.none;
  }

  /// There is something to keep and it differs from the draft as opened or as
  /// last saved.
  bool get hasUnsavedDraftChanges {
    if (!draftsActive) return false;
    final draft = currentDraft;
    return !draft.isEmpty &&
        (draft.text != _baseline.text ||
            draft.poll != _baseline.poll ||
            draft.replyAudience != _baseline.replyAudience ||
            draft.communityId != _baseline.communityId);
  }

  /// Loads the saved draft [id] of this account into the composer (picked in
  /// the Drafts list). [DraftLoadResult.gone] when it is missing (or not this
  /// account's) or the read failed; [DraftLoadResult.blockedByMedia] when it
  /// has a poll and photos or a GIF are attached (a poll excludes them, and
  /// neither is dropped silently). The composer is then left as it was.
  Future<DraftLoadResult> loadSavedDraft(String id) async {
    final repo = _drafts;
    if (repo == null || state.isSubmitting || _sessionOver) {
      return DraftLoadResult.gone;
    }
    try {
      final draft = await repo.read(_draftUid, id);
      if (draft == null || isClosed) return DraftLoadResult.gone;
      return loadDraft(draft);
    } catch (_, stack) {
      _reportDraftStorage(stack);
      return DraftLoadResult.gone;
    }
  }

  /// Puts [draft] into the composer (picked from the Drafts list): text, poll
  /// and audience, under the draft's own id. Nothing is saved by this.
  ///
  /// The same exclusions as the toolbar apply: a poll is loaded only
  /// when the rules offer one now (flags, gate memory, a root post), is
  /// refused while photos or a GIF are attached, and clears a schedule time
  /// (a schedule is never part of a draft, and a scheduled post has no poll).
  /// Ignored while the post is being sent.
  DraftLoadResult loadDraft(ComposerDraft draft) {
    if (state.isSubmitting ||
        _drafts == null ||
        draft.uid != _draftUid ||
        _sessionOver) {
      return DraftLoadResult.gone;
    }
    final loadsPoll = draft.poll != null && rules.showPoll;
    if (loadsPoll && state.hasAttachments) {
      return DraftLoadResult.blockedByMedia;
    }
    _base = draft;
    _baseline = draft;
    _draftDone = false;
    _loadingDraft = true;
    emit(
      state.copyWith(
        draft: analyzePostDraft(draft.text),
        poll: loadsPoll ? draft.poll : null,
        clearPoll: !loadsPoll,
        pollDurationClamped: false,
        replyAudience: canChooseReplyAudience
            ? draft.replyAudience
            : ReplyAudience.everyone,
        clearScheduledAt: loadsPoll,
        clearError: true,
        audience: ComposeAudience.everyone,
      ),
    );
    _loadingDraft = false;
    _pendingCommunityId = draft.communityId;
    _resolvePendingCommunity();
    return DraftLoadResult.loaded;
  }

  /// Keeps the content as a draft now ("Save"). Never throws: a storage
  /// failure is reported without the text and answers `skipped`.
  Future<DraftSaveResult> saveDraft() async {
    final repo = _drafts;
    // Never written once the session ended: the store would take it under the
    // next session.
    if (repo == null || _sessionOver) return DraftSaveResult.skipped;
    try {
      final saved = currentDraft;
      final result = await repo.upsert(saved);
      // Kept as it stands: leaving again without edits asks nothing.
      if (result != DraftSaveResult.skipped) _baseline = saved;
      return result;
    } catch (_, stack) {
      _reportDraftStorage(stack);
      return DraftSaveResult.skipped;
    }
  }

  /// Deletes the draft row ("Discard", a posted or scheduled post) and stops
  /// autosaving it.
  Future<void> discardDraft() async {
    final repo = _drafts;
    _draftDone = true;
    if (repo == null) return;
    try {
      await repo.delete(_draftUid, [_base.id]);
    } catch (_, stack) {
      _reportDraftStorage(stack);
    }
  }

  /// A storage failure is reported with its stack but never its message: a
  /// database error can carry the bound values, that is the draft's text.
  void _reportDraftStorage(StackTrace stack) =>
      _onUnexpectedError?.call(StateError('Drafts storage failed.'), stack);

  /// The content now lives as a scheduled post: its draft row is done and
  /// the emptied composer starts a new draft.
  void _draftScheduled() {
    final repo = _drafts;
    if (repo == null) return;
    unawaited(
      repo
          .delete(_draftUid, [_base.id])
          .then(
            (_) {},
            onError: (Object _, StackTrace stack) => _reportDraftStorage(stack),
          ),
    );
    _base = _baseDraft(_draftUid, null, _clock);
    _baseline = _base;
    _draftDone = false;
  }

  @override
  void onChange(Change<ComposerState> change) {
    super.onChange(change);
    final repo = _drafts;
    if (repo == null || _draftDone || _loadingDraft || _sessionOver) return;
    final a = change.currentState;
    final b = change.nextState;
    // Only edits are kept: not sending, not the reset after a schedule.
    if (b.status != ComposerStatus.editing || b.scheduledNotice != null) {
      return;
    }
    if (a.draft.text == b.draft.text &&
        a.poll == b.poll &&
        a.replyAudience == b.replyAudience &&
        a.audience == b.audience) {
      return;
    }
    repo.autosave(
      _base.copyWith(
        text: b.draft.text,
        poll: b.poll,
        clearPoll: b.poll == null,
        replyAudience: b.replyAudience,
        communityId: _draftCommunity(b),
      ),
    );
  }

  /// The post being replied to; empty for a top-level post.
  final String replyToPostId;

  /// The post being quoted (`CreatePost.quote_of_post_id`); empty
  /// for a plain post or a reply. A quote is a top-level post with the same
  /// 280 limit, text or photos, and an embed of the original.
  final String quoteOfPostId;

  /// `reply_audience` is on for this viewer. Only then, and
  /// only for a root post or a quote (never a reply), may the user pick who
  /// can reply; otherwise the request always carries UNSPECIFIED.
  final bool replyAudienceEnabled;

  /// `communities` is on for this viewer and the caller is not protected (the
  /// screen decides; the server answers PROTECTED_ACCOUNT otherwise).
  final bool communitiesEnabled;
  final CommunitiesRepository? _communities;

  /// A community id (from a draft, or the community page) not yet matched
  /// with the caller's communities; empty once it is chosen or dropped.
  String _pendingCommunityId;

  /// Also false once the server answered FEATURE_DISABLED for it (the gate
  /// remembers that until the next `GetMe`).
  bool get canChooseReplyAudience =>
      replyAudienceEnabled &&
      replyToPostId.isEmpty &&
      // A community conversation is members only and takes no policy of its
      // own: the control goes while a community is chosen.
      !state.audience.isCommunity &&
      _repository.subFeatureEnabled(kFeatureReplyAudience);

  /// `posts` and `scheduled_posts` are both on for this viewer
  ///Only then, and only for a new root post, may the user
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

  /// The raw flags the composer's toolbar rules read: `polls`
  /// and `engagement` for the poll, `gif` and `media` for the GIF button. The
  /// gate's session-long FEATURE_DISABLED memory is added by [rules].
  final bool pollsFlag;
  final bool engagementOn;
  final bool gifFlag;
  final bool mediaOn;

  /// The one answer to "which toolbar buttons are on": the screen and
  /// every cubit guard read it, none restates a rule. Reads the gate live, so
  /// a `FEATURE_DISABLED feature=polls` hides the button for the session.
  ComposerAttachmentRules get rules => ComposerAttachmentRules(
    flagPolls: pollsFlag && _repository.subFeatureEnabled(kFeaturePolls),
    engagementOn: engagementOn,
    // A FEATURE_DISABLED `gif` answer is remembered by the posts gate.
    flagGif: gifFlag && _repository.subFeatureEnabled(kFeatureGif),
    mediaOn: mediaOn,
    isReply: replyToPostId.isNotEmpty,
    isQuote: quoteOfPostId.isNotEmpty,
    hasPhotos: state.hasAttachments && !_gifHeld,
    hasGif: _gifHeld,
    hasPoll: state.hasPoll,
    // A time is only in force while the composer can still schedule.
    scheduled: state.isScheduling && canSchedule,
    inCommunity: state.audience.isCommunity,
  );

  bool get _gifHeld => _attachments?.state.hasGif ?? false;

  PostKind get _postKind => replyToPostId.isNotEmpty
      ? PostKind.reply
      : quoteOfPostId.isNotEmpty
      ? PostKind.quote
      : PostKind.post;

  PostMedia _mediaKind(List<String> mediaIds) => mediaIds.isEmpty
      ? PostMedia.none
      : _gifHeld
      ? PostMedia.gif
      : PostMedia.photo;

  final PostsRepository _repository;
  final UsageReporter _usage;
  final PendingPostsCubit? _pending;
  final common.AuthorSnapshot? _author;
  final AttachmentsCubit? _attachments;
  final void Function(Object error, StackTrace stack)? _onUnexpectedError;
  StreamSubscription<AttachmentsState>? _attachmentsSub;
  final Uuid _uuid;
  final DateTime Function() _clock;

  /// The signed-in session's generation (`AppDatabase.sessionEpoch`, the one
  /// the posts repository writes its cache under). The composer belongs to
  /// the session it was opened in: once a sign-out or an account switch ends
  /// it, nothing is sent, uploaded or saved any more (also when the screen
  /// is still open), and the screen leaves. Without one (tests, a reply) a
  /// private epoch that never ends is used.
  final SessionEpoch _session;
  late final int _openedSession;
  StreamSubscription<int>? _sessionSub;

  bool get _sessionOver => _session.value != _openedSession;

  /// Says once that the session ended; the screen then leaves.
  void _sessionHasEnded() {
    if (isClosed || state.sessionEnded) return;
    emit(state.copyWith(sessionEnded: true));
  }

  /// The send key claimed on the draft row for the send in flight.
  ({String key, bool reused})? _claimed;
  bool _forceNewKey = false;

  /// The keys this cubit has claimed on a draft row, per operation (draft,
  /// kind and, for a schedule, the publish time). The only key a send may use
  /// when the store cannot be read: it is the key the row held for that very
  /// operation, so the server replays or answers IDEMPOTENCY_KEY_REUSED and
  /// can never create a second post. Dropped once that key is proven unused
  /// or its post exists.
  final Map<String, String> _claimedKeys = {};

  String _claimSlot(String draftId, SendKind kind, DateTime? publishAt) =>
      '$draftId\u0001${kind.name}\u0001'
      '${publishAt?.toUtc().millisecondsSinceEpoch ?? ''}';

  void _forgetClaimedKey(String key) =>
      _claimedKeys.removeWhere((_, k) => k == key);

  /// Whether this send keeps its key on the draft row. An image-only post has
  /// no row to keep one on (in-memory keys). Checked before any await so a
  /// composer without drafts still adds its optimistic row in the same turn.
  bool get _claims => _drafts != null && !_draftDone && !currentDraft.isEmpty;

  static const _noClaim = (key: null, reused: false, refused: false);

  /// Claims the stored key of this send, or refuses it (the state was
  /// emitted). Only called when [_claims].
  ///
  /// When the store fails, the send goes out only under a key this cubit
  /// already claimed for the same operation; otherwise it is refused (a key
  /// the row does not hold could duplicate a post whose response was lost).
  Future<({String? key, bool reused, bool refused})> _claim(
    SendKind kind, {
    required bool force,
    DateTime? publishAt,
  }) async {
    final repo = _drafts!;
    final draft = currentDraft;
    final slot = _claimSlot(draft.id, kind, publishAt);
    try {
      final claim = await repo.claimSend(
        draft: draft,
        kind: kind,
        publishAt: publishAt,
        newKey: _uuid.v4,
        forceNew: force,
      );
      final key = claim.key;
      if (key == null) {
        if (!isClosed) {
          emit(
            state.copyWith(
              status: ComposerStatus.editing,
              sendConflict: switch (claim.block!) {
                SendBlock.rowGone => SendConflict.draftGone,
                SendBlock.unconfirmed => SendConflict.unconfirmed,
                SendBlock.otherKind =>
                  claim.pendingKind == SendKind.schedule
                      ? SendConflict.pendingSchedule
                      : SendConflict.pendingPost,
              },
            ),
          );
        }
        return (key: null, reused: false, refused: true);
      }
      _claimed = (key: key, reused: claim.reused);
      _claimedKeys[slot] = key;
      return (key: key, reused: claim.reused, refused: false);
    } catch (_, stack) {
      _reportDraftStorage(stack);
      // "Send anyway" asked for a NEW key, which cannot be stored now: the
      // old one would only be refused again, and an unstored one could
      // duplicate the post.
      final known = force ? null : _claimedKeys[slot];
      if (known != null) {
        // The row may have held it since an earlier send: never released.
        _claimed = (key: known, reused: true);
        return (key: known, reused: true, refused: false);
      }
      if (!isClosed) {
        emit(
          state.copyWith(
            status: ComposerStatus.editing,
            error: const UnknownApiException('Something went wrong.'),
          ),
        );
      }
      return (key: null, reused: false, refused: true);
    }
  }

  /// Whether the send in flight may still go out: the screen is open and the
  /// session is the one the composer was opened in. If not, nothing is sent:
  /// a key freshly claimed for it is released and, while the screen is open,
  /// the composer leaves `submitting` (no error: nothing failed, the account
  /// changed) and says the session ended.
  bool _mayStillSend() {
    if (!isClosed && !_sessionOver) return true;
    _releaseClaim();
    if (!isClosed) {
      emit(
        state.copyWith(
          status: ComposerStatus.editing,
          sessionEnded: _sessionOver ? true : null,
        ),
      );
    }
    return false;
  }

  /// The send stopped before any RPC (an upload failed): a key minted for it
  /// proves nothing was sent, so it is dropped; a reused one stays.
  void _releaseClaim() {
    final claimed = _claimed;
    _claimed = null;
    if (claimed != null && !claimed.reused) _clearClaim(claimed);
  }

  void _clearClaim(({String key, bool reused}) claimed) {
    _forgetClaimedKey(claimed.key);
    final repo = _drafts;
    if (repo == null) return;
    unawaited(
      repo
          .clearSend(_draftUid, _base.id, claimed.key)
          .then(
            (_) {},
            onError: (Object _, StackTrace stack) => _reportDraftStorage(stack),
          ),
    );
  }

  /// "Post this version too" / "Send anyway" after a [SendConflict]: sends
  /// again under a NEW key, the user's explicit choice.
  Future<void> sendAnyway() {
    _forceNewKey = true;
    return submit();
  }

  /// The conflict was shown.
  void sendConflictShown() {
    if (state.sendConflict != null) {
      emit(state.copyWith(clearSendConflict: true));
    }
  }

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
    await _sessionSub?.cancel();
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
        audience: state.audience,
        communityChoices: state.communityChoices,
        audienceNotice: state.audienceNotice,
        sessionEnded: state.sessionEnded,
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
    // A poll cannot be scheduled (SchedulePost has no poll field):
    // the same rules object that disables the button refuses it here.
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

  /// Whether the audience picker is offered: `communities` is on and
  /// the caller is not protected (both decided by the screen), a new root post
  /// or quote (never a reply), no schedule time set (SchedulePost takes no
  /// community), the caller is in at least one community, and the server has
  /// not answered FEATURE_DISABLED for it (the gate remembers that).
  bool get canChooseCommunity =>
      communitiesEnabled &&
      replyToPostId.isEmpty &&
      !state.isScheduling &&
      state.communityChoices.isNotEmpty &&
      _repository.subFeatureEnabled(kFeatureCommunities);

  /// The `community_id` the next CreatePost carries: only a community the
  /// picker offers right now, never a stale one.
  String get _communityToSend =>
      canChooseCommunity && state.audience.isCommunity
      ? state.audience.communityId
      : '';

  /// Picks where the post goes (the "Choose audience" sheet). A community must
  /// be one the caller is in ([ComposerState.communityChoices]); ignored while
  /// the picker is not offered and while the post is being sent.
  void audienceChanged(ComposeAudience audience) {
    if (!canChooseCommunity || state.isSubmitting) return;
    if (audience == state.audience) return;
    if (audience.isCommunity &&
        !state.communityChoices.any(
          (c) => c.communityId == audience.communityId,
        )) {
      return;
    }
    // An explicit choice settles what an unmatched draft id was waiting for.
    _pendingCommunityId = '';
    emit(state.copyWith(audience: audience, clearError: true));
  }

  /// Reads the caller's communities for the picker: the session cache when it
  /// has them (0 calls), else one ListMyCommunities shared with the
  /// Communities screen. Nothing is read while the picker cannot be offered.
  /// A failure leaves the picker out and the post going to everyone; it is
  /// said once when a community was asked for (a draft, the community page).
  Future<void> loadAudiences() async {
    final repo = _communities;
    if (repo == null || !communitiesEnabled || replyToPostId.isNotEmpty) return;
    // Always answer after the caller's first build, also from the cache: the
    // screen starts listening in that build, and a notice emitted before it
    // would be missed.
    await Future<void>.value();
    if (isClosed) return;
    try {
      final mine = repo.cachedMine ?? await repo.myCommunities();
      if (isClosed) return;
      _applyChoices(mine);
    } on AppException {
      if (isClosed) return;
      if (_pendingCommunityId.isNotEmpty) {
        emit(state.copyWith(audienceNotice: AudienceNotice.couldNotLoad));
      }
    } catch (error, stack) {
      _onUnexpectedError?.call(error, stack);
    }
  }

  /// The caller's communities were read (even when there are none).
  bool _choicesLoaded = false;

  void _applyChoices(MyCommunities mine) {
    _choicesLoaded = true;
    final choices = [
      for (final c in mine.communities)
        // Joined and open: a banned or archived community takes no post.
        if (c.role.isMember &&
            c.status != pbc.CommunityStatus.COMMUNITY_STATUS_ARCHIVED)
          c,
    ];
    final keep =
        state.audience.isCommunity &&
        choices.any((c) => c.communityId == state.audience.communityId);
    emit(
      state.copyWith(
        communityChoices: choices,
        audience: keep ? null : ComposeAudience.everyone,
      ),
    );
    _resolvePendingCommunity();
  }

  /// Matches the community a draft or the community page asked for with the
  /// loaded choices: found, it is chosen; not found, the post goes to
  /// everyone and the user is told once. Waits until the
  /// choices have loaded.
  void _resolvePendingCommunity() {
    final id = _pendingCommunityId;
    if (id.isEmpty || !communitiesEnabled) return;
    if (!_choicesLoaded) return;
    final found = state.communityChoices.where((c) => c.communityId == id);
    _pendingCommunityId = '';
    if (found.isNotEmpty) {
      if (!state.isScheduling) {
        emit(state.copyWith(audience: found.first.composeAudience));
      }
      return;
    }
    // The draft no longer names a community the caller is in: it is an
    // Everyone draft now, and leaving without edits asks nothing.
    _baseline = _baseline.copyWith(communityId: '');
    _base = _base.copyWith(communityId: '');
    emit(state.copyWith(audienceNotice: AudienceNotice.notAMember));
  }

  /// The notice was shown: forget it.
  void audienceNoticeShown() {
    if (state.audienceNotice != null) {
      emit(state.copyWith(clearAudienceNotice: true));
    }
  }

  /// The policy the next CreatePost carries: UNSPECIFIED unless a narrower
  /// audience is allowed and chosen (an explicit Everyone is UNSPECIFIED too).
  ReplyPolicy get _policyToSend => canChooseReplyAudience
      ? state.replyAudience.wire
      : ReplyPolicy.REPLY_POLICY_UNSPECIFIED;

  static const _noUploads = UploadedAttachments(mediaIds: [], altTexts: []);

  bool get _hasAttached => _attachments != null && !_attachments.state.isEmpty;

  /// Uploads the attached images first and returns their ids and alt
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
    // Likewise for a GIF once a CreatePost answered FEATURE_DISABLED `gif`
    // (the gate remembers it): do not upload what cannot be posted.
    if (attachments.state.hasGif &&
        !_repository.subFeatureEnabled(kFeatureGif)) {
      emit(
        state.copyWith(
          status: ComposerStatus.editing,
          error: const FeatureDisabledException(
            'GIFs are not available.',
            feature: kFeatureGif,
          ),
          uploadFailed: true,
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
    // The poll is part of the request. Keyed on the NORMALISED
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
    final force = _forceNewKey;
    _forceNewKey = false;
    if (!state.canSubmit) return;
    // Opened under another session (the account changed with the screen
    // open): nothing leaves, on this tap or any later one.
    if (_sessionOver) return _sessionHasEnded();
    final publishAt = state.scheduledAt;
    // SchedulePost has no poll field: a poll never takes that path (the
    // rules already keep the two apart; this is the last guard).
    if (publishAt != null && !state.hasPoll) {
      return _submitScheduled(publishAt, force);
    }
    final text = state.draft.text;
    final poll = state.poll;
    emit(
      state.copyWith(
        status: ComposerStatus.submitting,
        clearError: true,
        clearCreated: true,
        clearSendConflict: true,
      ),
    );
    // A draft-backed send claims its stored key before anything leaves (and
    // before any upload, so a refusal costs no Vision units).
    final claim = _claims
        ? await _claim(SendKind.post, force: force)
        : _noClaim;
    if (claim.refused) return;
    // Closed or signed out while claiming: no upload starts either.
    if (!_mayStillSend()) return;

    // On-device previews for the optimistic row (taken before upload).
    final thumbnails = [
      for (final a in _attachments?.state.items ?? const <Attachment>[])
        if (a.previewBytes != null) a.previewBytes!,
    ];
    // No await without photos: the optimistic row appears in the same turn.
    final uploaded = _hasAttached ? await _uploadAttached() : _noUploads;
    if (uploaded == null) return _releaseClaim();
    final mediaIds = uploaded.mediaIds;
    final altTexts = uploaded.altTexts;
    final media = _mediaKind(mediaIds);

    final policy = _policyToSend;
    // Read once, after the uploads: what is sent is what the pill showed.
    final communityId = _communityToSend;
    final bodyWithPolicy = _bodyKey(text, mediaIds, altTexts, policy, poll);
    // The server answers IDEMPOTENCY_KEY_REUSED for one key with another
    // community, so a community post has its own key; a post without one keeps
    // the key it always had.
    final bodyWithCommunity = communityId.isEmpty
        ? bodyWithPolicy
        : 'c:$communityId\u0001$bodyWithPolicy';
    // A quote and a plain post with the same body are different requests.
    final intent = quoteOfPostId.isEmpty
        ? bodyWithCommunity
        : 'q:$quoteOfPostId\u0001$bodyWithCommunity';
    // The last check before anything leaves: no await from here to the
    // repository reading the session as createPost starts, and no optimistic
    // row of the old account.
    if (!_mayStillSend()) return;
    final key = claim.key ?? _keyFor(intent);

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
        communityId: communityId,
      );
      // The server accepted the post: reported even if the screen closed.
      _usage.log(
        PostCreated(
          kind: _postKind,
          media: media,
          poll: poll != null,
          scheduled: false,
        ),
      );
      _keys.remove(intent);
      _keyText = null;
      _claimed = null;
      _forgetClaimedKey(key);
      pending?.remove(key);
      // The post exists: its draft row is done (also when the screen closed).
      unawaited(discardDraft());
      if (!isClosed) {
        // Echo check: an older revision may have dropped the
        // field, leaving the post open to everyone. Warn; never fail.
        // A community post takes no policy of its own: nothing to compare.
        final notApplied =
            communityId.isEmpty &&
            !replyPoliciesMatch(policy, created.post.replyPolicy);
        emit(
          state.copyWith(
            status: ComposerStatus.posted,
            created: created,
            replyPolicyNotApplied: notApplied,
            // Echo check: an older revision drops the field
            // and posts the question alone.
            pollNotAdded: poll != null && !created.post.hasPoll(),
            // Echo check: an older revision drops the field
            // and posts to everyone.
            communityNotApplied:
                communityId.isNotEmpty && !created.post.hasCommunity(),
          ),
        );
      }
    } on AppException catch (e) {
      _fail(key, e);
    } catch (_) {
      _fail(key, const UnknownApiException('Something went wrong.'));
    }
  }

  /// Schedules the post for [publishAt]: the same uploads as Post,
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
  Future<void> _submitScheduled(DateTime publishAt, bool force) async {
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
        clearSendConflict: true,
      ),
    );
    final claim = _claims
        ? await _claim(SendKind.schedule, force: force, publishAt: publishAt)
        : _noClaim;
    if (claim.refused) return;
    if (!_mayStillSend()) return;
    final uploaded = _hasAttached ? await _uploadAttached() : _noUploads;
    if (uploaded == null) return _releaseClaim();
    final media = _mediaKind(uploaded.mediaIds);
    final policy = _policyToSend;
    final intent =
        's:${publishAt.millisecondsSinceEpoch}\u0001'
        '${_bodyKey(text, uploaded.mediaIds, uploaded.altTexts, policy)}';
    if (!_mayStillSend()) return;
    final key = claim.key ?? _keyFor(intent);
    try {
      final scheduled = await _repository.schedulePost(
        idempotencyKey: key,
        text: text,
        publishAt: publishAt,
        mediaIds: uploaded.mediaIds,
        mediaAltTexts: uploaded.altTexts,
        replyPolicy: policy,
      );
      _usage.log(
        PostCreated(
          kind: _postKind,
          media: media,
          poll: false,
          scheduled: true,
        ),
      );
      _keys.remove(intent);
      _keyText = null;
      _claimed = null;
      _forgetClaimedKey(key);
      _draftScheduled();
      if (isClosed) return;
      emit(
        ComposerState(
          draft: analyzePostDraft(''),
          scheduledNotice: scheduled,
          communityChoices: state.communityChoices,
          sessionEnded: state.sessionEnded,
        ),
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
    final claimed = _claimed;
    _claimed = null;
    if (claimed != null && claimed.key == key) {
      if (error is IdempotencyKeyReusedException) {
        // The server knows this key with another body: an earlier version was
        // sent. The key stays (the user may reopen and ask again).
        if (isClosed) return;
        emit(
          state.copyWith(
            status: ComposerStatus.editing,
            sendConflict: SendConflict.earlierVersionSent,
          ),
        );
        return;
      }
      // Only a FRESH key whose first use was refused proves nothing was
      // created. A reused key may have landed on an earlier try, and
      // MEDIA_NOT_READY is ambiguous (the media may already be attached to a
      // post that landed), as are quota answers (review m1).
      final proves =
          error is ValidationException ||
          error is FeatureDisabledException ||
          error is EmailNotVerifiedException;
      if (!claimed.reused && proves) _clearClaim(claimed);
    }
    if (isClosed) return;
    // The server refused the audience (flag off): fall back to Everyone so
    // the user can still post (the gate also stops sending it).
    final audienceRefused =
        error is FeatureDisabledException &&
        error.feature == kFeatureReplyAudience;
    final pollsRefused =
        error is FeatureDisabledException && error.feature == kFeaturePolls;
    // The server will not take a post into this community (communities are
    // off, the caller left or was banned): back to Everyone, so the user can
    // still post, and the community leaves the picker. The gate remembers a
    // FEATURE_DISABLED itself.
    // Left, banned, archived or gone: this community is no longer a place to
    // post, so it also leaves the picker and the session cache.
    final communityGone =
        state.audience.isCommunity &&
        (error is CommunityForbiddenException &&
                (error.reason == CommunityForbiddenReason.notMember ||
                    error.reason == CommunityForbiddenReason.banned) ||
            error is CommunityStateException ||
            error is NotFoundException && quoteOfPostId.isEmpty);
    final communityRefused =
        communityGone ||
        state.audience.isCommunity &&
            (error is FeatureDisabledException &&
                    error.feature == kFeatureCommunities ||
                error is ProtectedAccountException);
    if (communityGone) {
      final id = state.audience.communityId;
      _communities?.forgetCommunity(id);
      emit(
        state.copyWith(
          communityChoices: [
            for (final c in state.communityChoices)
              if (c.communityId != id) c,
          ],
        ),
      );
    }
    emit(
      state.copyWith(
        status: ComposerStatus.editing,
        error: error,
        audience: communityRefused ? ComposeAudience.everyone : null,
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
