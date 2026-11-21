part of 'encrypted_sender.dart';

// The sender's private types and stateless helpers, moved here unchanged
// (as the receiver keeps its own in part files).

/// An answer that does not say whether the server stored the message: no
/// connection, the 30 s timeout, UNAVAILABLE (with or without a retry
/// time), an answer the client cannot read, or a call that was not let
/// through (the session, App Check, a paused service). The same request is
/// sent again; nothing is encrypted again.
bool _outcomeUnknown(AppException e) => switch (e) {
  NetworkException() ||
  ScreeningUnavailableException() ||
  UnknownApiException() ||
  UnauthenticatedException() ||
  AppCheckRequiredException() ||
  ServicePausedException() => true,
  _ => false,
};

/// [_outcomeUnknown] and [_errorName] for Task 8's init sends (the same
/// classification and the same stored names; never a second copy).
bool sendOutcomeUnknown(AppException e) => _outcomeUnknown(e);
String sendErrorName(AppException e) => _errorName(e);

/// The stored `lastError`: the type's name, written out (a runtime type
/// name is minified on the web), never the server's text.
String _errorName(AppException e) => switch (e) {
  CannotMessageException() => 'CannotMessageException',
  FeatureDisabledException() => 'FeatureDisabledException',
  EmailNotVerifiedException() => 'EmailNotVerifiedException',
  LimitReachedException() => 'LimitReachedException',
  RateLimitedException() => 'RateLimitedException',
  QuotaExceededException() => 'QuotaExceededException',
  DegradedModeException() => 'DegradedModeException',
  ValidationException() => 'ValidationException',
  AccountRestrictedException() => 'AccountRestrictedException',
  EncryptionRequiredException() => 'EncryptionRequiredException',
  NotFoundException() => 'NotFoundException',
  _ => 'AppException',
};

/// [r] with its attempts or its error changed; every other field as it is.
OutboxItem _copy(OutboxItem r, {int? attempts, required String? lastError}) =>
    OutboxItem(
      idempotencyKey: r.idempotencyKey,
      localId: r.localId,
      expectedMessageId: r.expectedMessageId,
      conversationId: r.conversationId,
      recipientUserId: r.recipientUserId,
      generation: r.generation,
      epoch: r.epoch,
      ciphertext: r.ciphertext,
      reportCommitment: r.reportCommitment,
      content: r.content,
      createdAtMicros: r.createdAtMicros,
      stage: r.stage,
      init: r.init,
      attempts: attempts ?? r.attempts,
      lastError: lastError,
    );

/// The answer's `created_at` in microseconds; null when it is unset or not
/// a time this client holds exactly.
int? _serverMicros(pb.Message m) {
  if (!m.hasCreatedAt()) return null;
  final seconds = m.createdAt.seconds;
  final nanos = m.createdAt.nanos;
  if (seconds.isNegative || seconds > _maxSeconds) return null;
  if (nanos < 0 || nanos > 999999999) return null;
  final micros = seconds.toInt() * 1000000 + nanos ~/ 1000;
  return micros > kMaxPairComponent ? null : micros;
}

/// What `outgoing` says of an encrypted row held for attribution: the plain
/// row's gate answer [gate] (it is never `none` then; `notSynced` if so).
SendBlock _owedReason(SendBlock gate) =>
    gate == SendBlock.none ? SendBlock.notSynced : gate;

/// The stronger of two priorities ([BudgetPriority] lists the strongest
/// first); [b] when [a] is null.
BudgetPriority _stronger(BudgetPriority? a, BudgetPriority b) =>
    a != null && a.index < b.index ? a : b;

/// A programming error, never an expected failure (a closed vault is a
/// [StateError]).
bool _isBug(Object e) => e is Error && e is! StateError;

String _hexOf(Uint8List b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

/// What a step asks of the drain: stop, take the next step, or run the live
/// pull and then take the next step.
enum _Next { stop, again, pull }

/// One drain's own counters.
class _Run {
  _Run(this.priority);

  final BudgetPriority priority;

  /// The catch-up and live pull of the sync gate ran: once in a drain, and
  /// once more after a successful accept (which sets this false again).
  bool synced = false;
  CatchUpResult? catchUp;

  /// The one accept call was made.
  bool accepted = false;
  int staleRounds = 0;

  /// The key and the local id of the row a `STALE_EPOCH` answer came for,
  /// until the step after its live pull.
  ({String key, String localId})? stale;

  /// The server's retry time of an unknown outcome: one resend is
  /// scheduled when the drain's steps have ended.
  Duration? resendAfter;
}

/// The vault the operation started with is no longer the session's.
class _Stopped implements Exception {
  const _Stopped();
}

/// The random source answered another length than was asked.
class _BadRandom implements Exception {
  const _BadRandom();
}

/// One step's vault, user and device; no `toString`.
class _Op {
  _Op(this.session, this.vault, this.uid, this.deviceId);

  final VaultSession session;
  final SecureVault vault;
  final String uid;
  final Uint8List deviceId;

  bool get live {
    final v = session.vault;
    return identical(v, vault) && v?.uid == uid;
  }

  bool owns(SecureVault v) => identical(v, vault) && v.uid == uid && live;

  /// The first thing every runWrite body does.
  void check(SecureVault v) {
    if (!owns(v)) throw const _Stopped();
  }
}

Future<OutboxItem?> _rowOf(SecureVault v, String id, String key) async {
  for (final r in (await v.outbox(conversationId: id)).items) {
    if (r.idempotencyKey == key) return r;
  }
  return null;
}

/// The highest stored non-provisional group, or null.
Future<GroupRecord?> _currentGroup(SecureVault vault, String id) async {
  GroupRecord? current;
  for (final group in await vault.groups(id)) {
    if (!group.provisional) current = group; // ascending generation
  }
  return current;
}

/// The server's retry time of an unknown outcome, capped at
/// [kMaxServerRetryWait] (security read L1); null when it named none.
Duration? _retryAfterOf(AppException e) {
  final wait = e is ScreeningUnavailableException ? e.retryAfter : null;
  if (wait == null || wait <= Duration.zero) return null;
  return wait > kMaxServerRetryWait ? kMaxServerRetryWait : wait;
}
