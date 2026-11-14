part of 'composer_cubit.dart';

/// Unsent-post persistence: the draft row, autosave, load, save and discard.
mixin _ComposerDrafts on _ComposerHost {
  /// Unsent posts are in use: `drafts` is on (the screen passes a repository
  /// only then), for a new root post.
  bool get draftsActive => _drafts != null && !_draftDone && !_sessionOver;

  /// The draft's id (the same row until it is posted or discarded).
  String get draftId => _base.id;

  /// The composer's content as a draft row.
  @override
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
      // The session may have ended while the row was read.
      if (draft == null || isClosed || _sessionOver) {
        return DraftLoadResult.gone;
      }
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
        draft: _analyze(draft.text),
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
  @override
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
  @override
  void _reportDraftStorage(StackTrace stack) =>
      _onUnexpectedError?.call(StateError('Drafts storage failed.'), stack);

  /// The content now lives as a scheduled post: its draft row is done and
  /// the emptied composer starts a new draft.
  @override
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
    _base = ComposerCubit._baseDraft(_draftUid, null, _clock);
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
}
