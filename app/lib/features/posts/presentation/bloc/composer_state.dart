part of 'composer_cubit.dart';

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
    this.beaconId = '',
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

  /// The plan attached to the post (`CreatePost.beacon_id`), empty for none.
  /// The user may remove it ([ComposerCubit.removePlan]); the server drops it
  /// (FEATURE_DISABLED `post_beacon_embed`) the same way.
  final String beaconId;

  bool get hasPlan => beaconId.isNotEmpty;
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
    String? beaconId,
    bool clearPlan = false,
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
    beaconId: clearPlan ? '' : (beaconId ?? this.beaconId),
  );
}
