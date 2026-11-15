part of 'composer_cubit.dart';

/// The composer's form: text, poll, schedule time, reply audience and
/// community audience.
mixin _ComposerForm on _ComposerHost {
  void textChanged(String raw) {
    if (state.isSubmitting) return;
    emit(
      ComposerState(
        draft: _analyze(raw),
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
        beaconId: state.beaconId,
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
  @override
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
  @override
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
  @override
  ReplyPolicy get _policyToSend => canChooseReplyAudience
      ? state.replyAudience.wire
      : ReplyPolicy.REPLY_POLICY_UNSPECIFIED;
}
