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
import '../../../beacons/domain/beacons_feature_flag.dart';
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
import '../../domain/post_intent.dart';
import 'pending_posts_cubit.dart';
import 'post_sender.dart';

part 'composer_claims.dart';
part 'composer_drafts.dart';
part 'composer_form.dart';
part 'composer_host.dart';
part 'composer_state.dart';
part 'composer_submit.dart';

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

class ComposerCubit extends Cubit<ComposerState>
    with
        _ComposerHost,
        _ComposerDrafts,
        _ComposerForm,
        _ComposerClaims,
        _ComposerSubmit {
  /// A top-level post: the optimistic item goes through [pending] with the
  /// viewer's [author] snapshot.
  ComposerCubit({
    required PostsRepository postsRepository,
    int Function()? postTextLimit,
    Stream<Object?>? postPolicyChanges,
    required PendingPostsCubit pending,

    /// When given, a plain root post is handed to it on Post and the
    /// composer closes at once (uploads and CreatePost run in the background).
    PostSender? sender,

    /// The key of an edited post that may already exist on the server.
    ({String key, DateTime startedAt})? resumeKey,
    required common.AuthorSnapshot author,
    this.quoteOfPostId = '',
    String beaconId = '',
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
  }) : _postTextLimit = postTextLimit,
       replyToPostId = '',
       _session = sessionEpoch ?? SessionEpoch(),
       _communities = communities,
       _pendingCommunityId = initialCommunityId.isNotEmpty
           ? initialCommunityId
           : (initialDraft?.communityId ?? ''),
       _usage = usage,
       _repository = postsRepository,
       _pending = pending,
       _sender = sender,
       _resumeKey = resumeKey,
       _author = author,
       _attachments = attachments,
       _onUnexpectedError = onUnexpectedError,
       _uuid = uuid ?? const Uuid(),
       _clock = clock ?? DateTime.now,
       // Unsent posts are for a new root post only: never a quote, and a
       // reply has its own constructor.
       // A plan attached at open is not kept in a draft either: the draft
       // would reopen without it.
       _drafts = quoteOfPostId.isEmpty && beaconId.isEmpty && uid.isNotEmpty
           ? drafts
           : null,
       _draftUid = uid,
       _base = _baseDraft(uid, initialDraft, clock ?? DateTime.now),
       super(
         _initialState(
           initialDraft,
           pollsOffered: pollsFlag && engagementOn,
           audienceEnabled: replyAudienceEnabled,
           // A plan rides on a root post, never on a quote.
           beaconId: quoteOfPostId.isEmpty ? beaconId : '',
         ),
       ) {
    _baseline = _base;
    revalidateTextLimit();
    _postPolicySub = postPolicyChanges?.listen((_) => revalidateTextLimit());
    if (postTextLimit != null) {
      _postPolicyTimer = Timer.periodic(
        const Duration(seconds: 30),
        (_) => revalidateTextLimit(),
      );
    }
    _openedSession = _session.value;
    _sessionSub = _session.ended.listen((_) => _sessionHasEnded());
    // Also the tile's Retry, which the grid calls on the attachments directly.
    attachments?.stopWhen(() => !_sessionOver);
    _watchAttachments();
  }

  /// A reply to [replyToPostId] (thread screen). Replies never appear on
  /// Home, so there is no optimistic item here: the thread screen shows its
  /// own pending row while [ComposerState.isSubmitting].
  ComposerCubit.reply({
    required PostsRepository postsRepository,
    int Function()? postTextLimit,
    Stream<Object?>? postPolicyChanges,
    required this.replyToPostId,
    Uuid? uuid,
    DateTime Function()? clock,
    UsageReporter usage = const UsageReporter.none(),
    SessionEpoch? sessionEpoch,
    // Photos or a GIF for the reply (the photo viewer's "Post your reply"
    // bar opens the composer with a picker); null keeps a text-only reply.
    AttachmentsCubit? attachments,
    this.gifFlag = false,
    this.mediaOn = false,
    void Function(Object error, StackTrace stack)? onUnexpectedError,
  }) : _postTextLimit = postTextLimit,
       quoteOfPostId = '',
       _session = sessionEpoch ?? SessionEpoch(),
       _usage = usage,
       _repository = postsRepository,
       _pending = null,
       _sender = null,
       _resumeKey = null,
       _author = null,
       _attachments = attachments,
       _onUnexpectedError = onUnexpectedError,
       _uuid = uuid ?? const Uuid(),
       _clock = clock ?? DateTime.now,
       replyAudienceEnabled = false,
       communitiesEnabled = false,
       _communities = null,
       _pendingCommunityId = '',
       scheduleEnabled = false,
       pollsFlag = false,
       engagementOn = false,
       _drafts = null,
       _draftUid = '',
       _base = _baseDraft('', null, clock ?? DateTime.now),
       super(ComposerState(draft: analyzePostDraft(''))) {
    _baseline = _base;
    _openedSession = _session.value;
    _sessionSub = _session.ended.listen((_) => _sessionHasEnded());
    attachments?.stopWhen(() => !_sessionOver);
    _watchAttachments();
    revalidateTextLimit();
    _postPolicySub = postPolicyChanges?.listen((_) => revalidateTextLimit());
    if (postTextLimit != null) {
      _postPolicyTimer = Timer.periodic(
        const Duration(seconds: 30),
        (_) => revalidateTextLimit(),
      );
    }
  }

  final int Function()? _postTextLimit;
  StreamSubscription<Object?>? _postPolicySub;
  Timer? _postPolicyTimer;

  @override
  PostDraft _analyze(String raw) => analyzePostDraft(
    raw,
    maxCodePoints: _postTextLimit?.call() ?? kMaxPostCodePoints,
  );

  @override
  void revalidateTextLimit() {
    if (isClosed || state.isSubmitting) return;
    final draft = _analyze(state.draft.text);
    if (draft.maxCodePoints != state.draft.maxCodePoints ||
        draft.problem != state.draft.problem) {
      emit(state.copyWith(draft: draft));
    }
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
    String beaconId = '',
  }) => d == null
      ? ComposerState(draft: analyzePostDraft(''), beaconId: beaconId)
      : ComposerState(
          beaconId: beaconId,
          draft: analyzePostDraft(d.text),
          // A poll or an audience the flags no longer offer is not loaded.
          poll: pollsOffered ? d.poll : null,
          replyAudience: audienceEnabled
              ? d.replyAudience
              : ReplyAudience.everyone,
        );

  @override
  final DraftsRepository? _drafts;
  @override
  final String _draftUid;

  /// The draft being written: its id, owner, creation time and the labels the
  /// composer has no control for (kept so a re-save does not clear them).
  /// Replaced by [loadDraft].
  @override
  ComposerDraft _base;

  /// The draft as opened (or the empty one): "changed since open" compares
  /// with it.
  @override
  late ComposerDraft _baseline;

  /// Stops autosaving once the draft was posted, scheduled or discarded.
  @override
  bool _draftDone = false;
  @override
  bool _loadingDraft = false;

  /// The post being replied to; empty for a top-level post.
  @override
  final String replyToPostId;

  /// The post being quoted (`CreatePost.quote_of_post_id`); empty
  /// for a plain post or a reply. A quote is a top-level post with the same
  /// 280 limit, text or photos, and an embed of the original.
  @override
  final String quoteOfPostId;

  /// `reply_audience` is on for this viewer. Only then, and
  /// only for a root post or a quote (never a reply), may the user pick who
  /// can reply; otherwise the request always carries UNSPECIFIED.
  final bool replyAudienceEnabled;

  /// `communities` is on for this viewer and the caller is not protected (the
  /// screen decides; the server answers PROTECTED_ACCOUNT otherwise).
  @override
  final bool communitiesEnabled;
  @override
  final CommunitiesRepository? _communities;

  /// A community id (from a draft, or the community page) not yet matched
  /// with the caller's communities; empty once it is chosen or dropped.
  @override
  String _pendingCommunityId;

  /// Also false once the server answered FEATURE_DISABLED for it (the gate
  /// remembers that until the next `GetMe`).
  @override
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
  @override
  bool get canSchedule =>
      scheduleEnabled &&
      replyToPostId.isEmpty &&
      quoteOfPostId.isEmpty &&
      // SchedulePost has no plan field: the plan would be dropped silently.
      !state.hasPlan &&
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
  @override
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
    hasPlan: state.hasPlan,
  );

  /// Takes the attached plan off the post (the preview's remove button). The
  /// next send carries no `beacon_id` and has its own idempotency key.
  void removePlan() {
    if (isClosed || !state.hasPlan) return;
    emit(state.copyWith(clearPlan: true, clearError: true));
  }

  bool get _gifHeld => _attachments?.state.hasGif ?? false;

  @override
  PostKind get _postKind => replyToPostId.isNotEmpty
      ? PostKind.reply
      : quoteOfPostId.isNotEmpty
      ? PostKind.quote
      : PostKind.post;

  @override
  PostMedia _mediaKind(List<String> mediaIds) => mediaIds.isEmpty
      ? PostMedia.none
      : _gifHeld
      ? PostMedia.gif
      : PostMedia.photo;

  @override
  final PostsRepository _repository;
  @override
  final UsageReporter _usage;
  @override
  final PendingPostsCubit? _pending;
  @override
  final PostSender? _sender;
  @override
  final ({String key, DateTime startedAt})? _resumeKey;
  @override
  final common.AuthorSnapshot? _author;
  @override
  final AttachmentsCubit? _attachments;
  @override
  final void Function(Object error, StackTrace stack)? _onUnexpectedError;
  StreamSubscription<AttachmentsState>? _attachmentsSub;
  @override
  final Uuid _uuid;
  @override
  final DateTime Function() _clock;

  /// The signed-in session's generation (`AppDatabase.sessionEpoch`, the one
  /// the posts repository writes its cache under). The composer belongs to
  /// the session it was opened in: once a sign-out or an account switch ends
  /// it, nothing is sent, uploaded or saved any more (also when the screen
  /// is still open), and the screen leaves (the thread's reply bar empties
  /// instead). Without one (tests) a private epoch that never ends is used.
  final SessionEpoch _session;
  late final int _openedSession;
  StreamSubscription<int>? _sessionSub;

  @override
  bool get _sessionOver => _session.value != _openedSession;

  /// The session this composer was opened in has ended, known at once (the
  /// state's [ComposerState.sessionEnded] follows on the next event).
  bool get sessionEnded => _sessionOver;

  /// Says once that the session ended; the screen then leaves (a composer
  /// screen) or empties its field (the thread's reply bar). The old account's
  /// text is dropped with it.
  @override
  void _sessionHasEnded() {
    if (isClosed || state.sessionEnded) return;
    emit(state.copyWith(sessionEnded: true, draft: analyzePostDraft('')));
  }

  void _watchAttachments() {
    final attachments = _attachments;
    if (attachments == null) return;
    // Photos that come with the composer (Edit on a failed post).
    final held = attachments.state;
    if (!held.isEmpty) {
      emit(
        state.copyWith(
          hasAttachments: true,
          attachmentsReady: held.isSendable && !held.isBusy,
        ),
      );
    }
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
    _postPolicyTimer?.cancel();
    await _postPolicySub?.cancel();
    await _sessionSub?.cancel();
    await _attachmentsSub?.cancel();
    return super.close();
  }
}
