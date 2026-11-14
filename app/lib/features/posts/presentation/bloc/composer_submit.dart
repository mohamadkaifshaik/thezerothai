part of 'composer_cubit.dart';

/// The send pipeline: idempotency keys, uploads, Post, Schedule and rollback.
mixin _ComposerSubmit on _ComposerHost {
  /// Idempotency key per submitted text, insertion-ordered and bounded.
  final Map<String, String> _keys = {};
  String? _keyText;

  /// The key of the current intent, for tests and diagnostics.
  @visibleForTesting
  String? get currentKey => _keyText == null ? null : _keys[_keyText];

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
      // No upload request starts once the session ended: A's photos must not
      // become media of the next account.
      final uploaded = await attachments.uploadAll(
        stillWanted: () => !_sessionOver,
      );
      // The screen may have gone while the photos uploaded: never create
      // a post nobody is waiting for (and never one that lost its photos).
      return isClosed ? null : uploaded;
    } on AppException catch (e) {
      // Already reported where it happened (repository / uploader): never
      // report an upload failure a second time here.
      if (isClosed) return null;
      if (_sessionOver) {
        // Stopped for the session: nothing failed, the screen leaves.
        emit(state.copyWith(status: ComposerStatus.editing));
        _sessionHasEnded();
        return null;
      }
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

  @override
  Future<void> submit() async {
    revalidateTextLimit();
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
          draft: _analyze(''),
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
