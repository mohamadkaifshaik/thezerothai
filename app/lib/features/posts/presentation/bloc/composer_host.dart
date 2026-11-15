part of 'composer_cubit.dart';

/// What the composer's parts (drafts, form, submit) read from the cubit and
/// from each other. Declarations only: [ComposerCubit] owns the fields and
/// each part implements its own methods.
mixin _ComposerHost on Cubit<ComposerState> {
  PostsRepository get _repository;
  DraftsRepository? get _drafts;
  String get _draftUid;
  ComposerDraft get _base;
  set _base(ComposerDraft value);
  ComposerDraft get _baseline;
  set _baseline(ComposerDraft value);
  bool get _draftDone;
  set _draftDone(bool value);
  bool get _loadingDraft;
  set _loadingDraft(bool value);
  String get _pendingCommunityId;
  set _pendingCommunityId(String value);
  CommunitiesRepository? get _communities;
  void Function(Object error, StackTrace stack)? get _onUnexpectedError;
  Uuid get _uuid;
  DateTime Function() get _clock;
  UsageReporter get _usage;
  PendingPostsCubit? get _pending;
  PostSender? get _sender;
  AttachmentsCubit? get _attachments;
  String get replyToPostId;
  String get quoteOfPostId;
  bool get communitiesEnabled;
  bool get _sessionOver;
  void _sessionHasEnded();
  ComposerAttachmentRules get rules;
  bool get canSchedule;
  bool get canChooseReplyAudience;
  PostDraft _analyze(String raw);
  void revalidateTextLimit();
  PostKind get _postKind;
  PostMedia _mediaKind(List<String> mediaIds);
  common.AuthorSnapshot? get _author;

  // Implemented by the drafts part.
  ComposerDraft get currentDraft;
  Future<void> discardDraft();
  Future<DraftSaveResult> saveDraft();
  void _draftScheduled();
  void _reportDraftStorage(StackTrace stack);

  // Implemented by the form part.
  void _resolvePendingCommunity();
  String get _communityToSend;
  ReplyPolicy get _policyToSend;

  // Implemented by the claims part.
  Map<String, ({String key, DateTime startedAt})> get _claimedKeys;
  String _claimSlot(String draftId, SendKind kind, DateTime? publishAt);
  ({String key, bool reused})? get _claimed;
  set _claimed(({String key, bool reused})? value);
  bool get _forceNewKey;
  set _forceNewKey(bool value);
  bool get _claims;
  Future<({String? key, bool reused, bool refused})> _claim(
    SendKind kind, {
    required bool force,
    DateTime? publishAt,
  });
  bool _mayStillSend();
  void _releaseClaim();
  void _clearClaim(({String key, bool reused}) claimed);
  void _forgetClaimedKey(String key);

  // Implemented by the submit part.
  Future<void> submit();
}
