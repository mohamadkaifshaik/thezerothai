part of 'composer_cubit.dart';

/// Send-key claims: the key stored on the draft row for the send in flight,
/// refusals and the conflicts the screen asks about.
const _noClaim = (key: null, reused: false, refused: false);

mixin _ComposerClaims on _ComposerHost {
  /// The send key claimed on the draft row for the send in flight.
  @override
  ({String key, bool reused})? _claimed;
  @override
  bool _forceNewKey = false;

  /// The keys this cubit has claimed on a draft row, per operation (draft,
  /// kind and, for a schedule, the publish time). The only key a send may use
  /// when the store cannot be read: it is the key the row held for that very
  /// operation, so the server replays or answers IDEMPOTENCY_KEY_REUSED and
  /// can never create a second post. Dropped once that key is proven unused
  /// or its post exists. Each key keeps the time it was first minted (the
  /// row's, never refreshed by a reuse), so it expires with the row's window
  /// ([sendKeyExpired]): past it the server may have forgotten the key.
  @override
  final Map<String, ({String key, DateTime startedAt})> _claimedKeys = {};

  @override
  String _claimSlot(String draftId, SendKind kind, DateTime? publishAt) =>
      '$draftId\u0001${kind.name}\u0001'
      '${publishAt?.toUtc().millisecondsSinceEpoch ?? ''}';

  @override
  void _forgetClaimedKey(String key) =>
      _claimedKeys.removeWhere((_, k) => k.key == key);

  /// Whether this send keeps its key on the draft row. An image-only post has
  /// no row to keep one on (in-memory keys). Checked before any await so a
  /// composer without drafts still adds its optimistic row in the same turn.
  @override
  bool get _claims => _drafts != null && !_draftDone && !currentDraft.isEmpty;

  /// Claims the stored key of this send, or refuses it (the state was
  /// emitted). Only called when [_claims].
  ///
  /// When the store fails, the send goes out only under a key this cubit
  /// already claimed for the same operation and still inside that key's
  /// window (past it, refused as unconfirmed, as the store would); otherwise
  /// it is refused (a key the row does not hold could duplicate a post whose
  /// response was lost).
  @override
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
        _refuse(switch (claim.block!) {
          SendBlock.rowGone => SendConflict.draftGone,
          SendBlock.unconfirmed => SendConflict.unconfirmed,
          SendBlock.otherKind =>
            claim.pendingKind == SendKind.schedule
                ? SendConflict.pendingSchedule
                : SendConflict.pendingPost,
        });
        return (key: null, reused: false, refused: true);
      }
      _claimed = (key: key, reused: claim.reused);
      // The store's mint time; without one, a key already remembered keeps
      // its own (a reuse never restarts the window).
      final prior = _claimedKeys[slot];
      _claimedKeys[slot] = (
        key: key,
        startedAt:
            claim.startedAt ??
            (prior != null && prior.key == key ? prior.startedAt : _clock()),
      );
      return (key: key, reused: claim.reused, refused: false);
    } catch (_, stack) {
      _reportDraftStorage(stack);
      // "Send anyway" asked for a NEW key, which cannot be stored now: the
      // old one would only be refused again, and an unstored one could
      // duplicate the post.
      final known = force ? null : _claimedKeys[slot];
      if (known != null) {
        final expired = sendKeyExpired(
          kind: kind,
          startedAt: known.startedAt,
          publishAt: publishAt,
          now: _clock(),
        );
        if (expired) {
          // The server may have forgotten it: a replay could post twice.
          // Kept, as the row keeps it: a later tap is refused the same way.
          _refuse(SendConflict.unconfirmed);
          return (key: null, reused: false, refused: true);
        }
        // The row may have held it since an earlier send: never released.
        _claimed = (key: known.key, reused: true);
        return (key: known.key, reused: true, refused: false);
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

  /// A send refused before anything left, for [conflict]: back to editing.
  void _refuse(SendConflict conflict) {
    if (isClosed) return;
    emit(
      state.copyWith(status: ComposerStatus.editing, sendConflict: conflict),
    );
  }

  /// Whether the send in flight may still go out: the screen is open and the
  /// session is the one the composer was opened in. If not, nothing is sent:
  /// a key freshly claimed for it is released and, while the screen is open,
  /// the composer leaves `submitting` (no error: nothing failed, the account
  /// changed) and says the session ended.
  @override
  bool _mayStillSend() {
    if (!isClosed && !_sessionOver) return true;
    _releaseClaim();
    if (!isClosed) {
      emit(state.copyWith(status: ComposerStatus.editing));
      if (_sessionOver) _sessionHasEnded();
    }
    return false;
  }

  /// The send stopped before any RPC (an upload failed): a key minted for it
  /// proves nothing was sent, so it is dropped; a reused one stays.
  @override
  void _releaseClaim() {
    final claimed = _claimed;
    _claimed = null;
    if (claimed != null && !claimed.reused) _clearClaim(claimed);
  }

  @override
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
}
